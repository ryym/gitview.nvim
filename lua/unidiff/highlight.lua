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

--- Collect per-line highlight segments for a whole buffer.
---
--- We iterate the `highlights` query directly rather than probing positions with
--- `vim.inspect_pos()`: probing is ~25x slower and its result carries no end
--- column, so there is no way to advance past a capture without re-probing every
--- single byte.
---
--- @param buf integer
--- @param lang string
--- @return table<integer, unidiff.Seg[]> segments keyed by 0-based row
function M.collect(buf, lang)
  local by_row = {}
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang)
  if not ok or not parser then
    return by_row
  end
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

return M
