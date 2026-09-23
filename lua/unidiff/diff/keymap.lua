--- What the keys do inside a diff buffer.
local dlib = require('unidiff.diff.lines')
local render = require('unidiff.diff.render')

local M = {}

--- @param dir 1|-1
--- @param field 'hunk_rows'|'files'
function M.jump(dir, field)
  local view = render.views[vim.api.nvim_get_current_buf()]
  if not view then
    return
  end
  local rows = {}
  for _, entry in ipairs(view[field]) do
    rows[#rows + 1] = type(entry) == 'table' and entry.row or entry
  end

  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  for _, r in ipairs(rows) do
    if dir > 0 and r > cur then
      target = r
      break
    elseif dir < 0 and r < cur then
      target = r
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

function M.goto_source()
  local buf = vim.api.nvim_get_current_buf()
  local view = render.views[buf]
  if not view then
    return
  end
  local l = view.lines[vim.api.nvim_win_get_cursor(0)[1]]
  -- separators and file headers point at no single source line
  if not l or not dlib.source_kinds[l.kind] then
    return
  end
  local path = view.files[l.file].path
  local lnum = l.new_lnum or l.old_lnum
  vim.cmd.tabclose()
  vim.cmd.edit(vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
end

--- @param buf integer
function M.set(buf)
  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, desc = desc })
  end
  map(']h', function()
    M.jump(1, 'hunk_rows')
  end, 'unidiff: next hunk')
  map('[h', function()
    M.jump(-1, 'hunk_rows')
  end, 'unidiff: previous hunk')
  map(']f', function()
    M.jump(1, 'files')
  end, 'unidiff: next file')
  map('[f', function()
    M.jump(-1, 'files')
  end, 'unidiff: previous file')
  map('q', '<Cmd>quit<CR>', 'unidiff: close')
  map('<CR>', M.goto_source, 'unidiff: jump to source line')
end

return M
