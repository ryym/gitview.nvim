local M = {}

--- @class unidiff.Seg
--- @field row integer 0-based
--- @field start_col integer byte column, inclusive
--- @field end_col integer byte column, exclusive
--- @field hl_group string
--- @field priority integer

-- Treesitter's own default; captures later in the query win ties.
local TS_PRIORITY = 100

--- Load a whole file version into a scratch buffer so the highlighter sees full
--- context (multi-line strings, injections, ...) instead of a hunk fragment.
--- @param lines string[]
--- @param filetype string
--- @return integer bufnr
function M.ghost_buffer(lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = filetype
  return buf
end

--- Collect segments from Tree-sitter by iterating the `highlights` query.
---
--- Probing positions with `vim.inspect_pos()` would be the obvious alternative,
--- but it is ~25x slower and its result carries no end column, so there is no
--- way to advance past a capture without re-probing every single byte.
---
--- @param buf integer
--- @param parser vim.treesitter.LanguageTree
--- @return table<integer, unidiff.Seg[]>
local function collect_treesitter(buf, parser)
  local by_row = {}
  -- Headless/unrendered buffers are never parsed implicitly, so force it here.
  parser:parse(true)

  parser:for_each_tree(function(tree, ltree)
    local ltlang = ltree:lang()
    local query = vim.treesitter.query.get(ltlang, 'highlights')
    if not query then
      return
    end
    for id, node, metadata in query:iter_captures(tree:root(), buf, 0, -1) do
      local capture = query.captures[id]
      if capture:sub(1, 1) ~= '_' then
        local sr, sc, er, ec = node:range()
        local prio = tonumber(metadata.priority or metadata[id] and metadata[id].priority)
          or TS_PRIORITY
        local hl = '@' .. capture .. '.' .. ltlang
        -- Split multi-row captures so each row can be replayed independently.
        for row = sr, er do
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
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

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

    for row = 0, #lines - 1 do
      local text = lines[row + 1]
      if #text > 0 and (rows == nil or rows[row]) then
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
  end)

  return by_row
end

--- Collect per-line highlight segments for a buffer, preferring Tree-sitter and
--- falling back to legacy `:syntax` for languages that have no parser.
---
--- @param buf integer
--- @param lang string
--- @param rows table<integer, true>? 0-based rows of interest. Only the legacy
---        path honours this; the Tree-sitter pass reads the whole tree anyway.
--- @return table<integer, unidiff.Seg[]> segments keyed by 0-based row
function M.collect(buf, lang, rows)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang)
  if ok and parser then
    return collect_treesitter(buf, parser)
  end
  return collect_syntax(buf, rows)
end

return M
