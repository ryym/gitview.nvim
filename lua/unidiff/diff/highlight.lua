local M = {}

--- @class unidiff.Seg
--- @field row integer 0-based
--- @field start_col integer byte column, inclusive
--- @field end_col integer byte column, exclusive
--- @field hl_group string
--- @field priority integer

-- Treesitter's own default; captures later in the query win ties.
local TS_PRIORITY = 100

--- Whether Tree-sitter can highlight `lang`, and so whether the ghost buffer
--- needs a filetype at all.
--- @param lang string
--- @return boolean
function M.has_parser(lang)
  if lang == '' then
    return false
  end
  -- `language.add` returns `true`, or `nil` plus a message when there is no
  -- parser; anything other than `true` means the legacy path has to take over.
  local ok, added = pcall(vim.treesitter.language.add, lang)
  return ok and added == true
end

--- Load a whole file version into a scratch buffer so the highlighter sees full
--- context (multi-line strings, injections, ...) instead of a hunk fragment.
---
--- Setting 'filetype' fires FileType, which loads the ftplugin and the syntax
--- file for every ghost buffer. That is only worth paying for when the legacy
--- `:syntax` path will actually be used: `vim.treesitter.get_parser()` takes the
--- language explicitly and does not care what the buffer's filetype is.
---
--- @param lines string[]
--- @param filetype string
--- @param lang string? language Tree-sitter would use, when it has a parser
--- @return integer bufnr
function M.ghost_buffer(lines, filetype, lang)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if not (lang and M.has_parser(lang)) then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

--- Turn a set of rows into the contiguous `[start, stop)` ranges that the
--- Tree-sitter query API takes. The ranges are disjoint, so a capture spanning
--- several of them is never emitted twice for the same row.
--- @param rows table<integer, true>
--- @return integer[][]
local function row_ranges(rows)
  local sorted = vim.tbl_keys(rows)
  table.sort(sorted)
  local ranges = {}
  for _, r in ipairs(sorted) do
    local last = ranges[#ranges]
    if last and last[2] == r then
      last[2] = r + 1
    else
      ranges[#ranges + 1] = { r, r + 1 }
    end
  end
  return ranges
end

--- Collect segments from Tree-sitter by iterating the `highlights` query.
---
--- Probing positions with `vim.inspect_pos()` would be the obvious alternative,
--- but it is ~25x slower and its result carries no end column, so there is no
--- way to advance past a capture without re-probing every single byte.
---
--- The whole buffer is parsed, because that is what makes a line deleted from
--- the middle of a multi-line string come out as a string. Only the query is
--- restricted to the rows the diff shows: a captures pass over a whole file
--- costs ~16x a pass over the handful of rows around its hunks, and the
--- captures it collects for invisible rows would only be thrown away.
--- Restricting the query is safe because a capture that starts before the range
--- is still reported inside it.
---
--- @param buf integer
--- @param parser vim.treesitter.LanguageTree
--- @param rows table<integer, true>? rows of interest; nil means all
--- @return table<integer, unidiff.Seg[]>
local function collect_treesitter(buf, parser, rows)
  local by_row = {}
  -- Headless/unrendered buffers are never parsed implicitly, so force it here.
  parser:parse(true)
  local ranges = rows and row_ranges(rows) or { { 0, -1 } }

  parser:for_each_tree(function(tree, ltree)
    local ltlang = ltree:lang()
    local query = vim.treesitter.query.get(ltlang, 'highlights')
    if not query then
      return
    end
    for _, range in ipairs(ranges) do
      for id, node, metadata in query:iter_captures(tree:root(), buf, range[1], range[2]) do
        local capture = query.captures[id]
        if capture:sub(1, 1) ~= '_' then
          local sr, sc, er, ec = node:range()
          local prio = tonumber(metadata.priority or metadata[id] and metadata[id].priority)
            or TS_PRIORITY
          local hl = '@' .. capture .. '.' .. ltlang
          -- Split multi-row captures so each row can be replayed independently,
          -- clipped to this range so overlapping captures are not duplicated.
          local from = math.max(sr, range[1])
          local to = range[2] < 0 and er or math.min(er, range[2] - 1)
          for row = from, to do
            local s = row == sr and sc or 0
            local e = row == er and ec or -1
            if not (row == er and ec == 0 and er > sr) then
              by_row[row] = by_row[row] or {}
              table.insert(by_row[row], {
                row = row,
                start_col = s,
                end_col = e,
                hl_group = hl,
                priority = prio,
              })
            end
          end
        end
      end
    end
  end)

  return by_row
end

--- Collect segments from legacy `:syntax` highlighting.
---
--- There is no bulk query for it, so positions have to be probed one byte at a
--- time. `vim.fn.synID()` is the cheap way to do that: `vim.inspect_pos()` also
--- reports Tree-sitter, semantic tokens and extmarks, and building those tables
--- per byte costs more than an order of magnitude more.
---
--- `synID()` only reads the current buffer, hence `nvim_buf_call`. Vim keeps its
--- own syntax state for the buffer and computes it from the preceding lines on
--- demand, so probing a subset of rows still yields context-correct results.
---
--- @param buf integer
--- @param rows table<integer, true>? 0-based rows to collect; nil means all
--- @return table<integer, unidiff.Seg[]>
local function collect_syntax(buf, rows)
  local by_row = {}

  --- The syntax item's own name is used rather than `synIDtrans()`'s resolved
  --- group: a syntax group is a highlight group, and extmarks follow `:hi link`
  --- chains when they are drawn, so the link stays live if the colorscheme
  --- changes while the diff is open. Both resolve to the same colors.
  --- @type table<integer, string|false>
  local names = {}
  local function name_of(id)
    local name = names[id]
    if name == nil then
      name = vim.fn.synIDattr(id, 'name')
      if name == '' then
        name = false
      end
      names[id] = name
    end
    return name
  end

  vim.api.nvim_buf_call(buf, function()
    if vim.bo.syntax == '' or vim.bo.syntax == 'OFF' then
      return
    end
    local synID = vim.fn.synID

    -- Only the rows of interest are read. `row_ranges` turns the set into the
    -- spans `nvim_buf_get_lines` takes, so a long file with a few changed lines
    -- is not copied into Lua whole.
    for _, range in ipairs(rows and row_ranges(rows) or { { 0, -1 } }) do
      local lines = vim.api.nvim_buf_get_lines(buf, range[1], range[2], false)
      for i, text in ipairs(lines) do
        local row = range[1] + i - 1
        if #text > 0 then
          local segs = {}
          local start, prev = 0, synID(row + 1, 1, 1)
          for byte = 1, #text do
            -- -1 at the end of the line forces the last run to be flushed
            local id = byte < #text and synID(row + 1, byte + 1, 1) or -1
            if id ~= prev then
              local name = prev ~= 0 and name_of(prev) or false
              if name then
                segs[#segs + 1] = {
                  row = row,
                  start_col = start,
                  end_col = byte,
                  hl_group = name,
                  -- same layer as Tree-sitter: above the diff background,
                  -- below the word-level highlights
                  priority = TS_PRIORITY,
                }
              end
              start, prev = byte, id
            end
          end
          if #segs > 0 then
            by_row[row] = segs
          end
        end
      end
    end
  end)

  return by_row
end

--- Collect per-line highlight segments for a buffer, preferring Tree-sitter and
--- falling back to legacy `:syntax` for languages that have no parser.
---
--- @param buf integer
--- @param lang string
--- @param rows table<integer, true>? 0-based rows of interest; nil means all
--- @return table<integer, unidiff.Seg[]> segments keyed by 0-based row
function M.collect(buf, lang, rows)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang)
  if ok and parser then
    return collect_treesitter(buf, parser, rows)
  end
  return collect_syntax(buf, rows)
end

return M
