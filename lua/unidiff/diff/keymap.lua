--- What the keys do inside a diff buffer.
---
--- Three of them depend on what the buffer is shown in. A diff opened by a
--- command owns its tab page, so closing means closing that tab; the same
--- buffer inside the file list is one pane of something larger, and moving
--- between files means moving the list's cursor. The keys are the same either
--- way, so what they call is passed in rather than branched on here.
local dlib = require('unidiff.diff.lines')
local render = require('unidiff.diff.render')

local M = {}

--- @class unidiff.DiffKeys
--- @field close fun() what `q` does
--- @field goto_file fun(dir: 1|-1) what `]f` and `[f` do
--- @field before_jump fun() run before `<CR>` opens the file the cursor is in

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

--- Open the file the cursor's row came from, at the line it stands for.
--- @param before_jump fun() gives up whatever the diff was being shown in
function M.goto_source(before_jump)
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
  before_jump()
  vim.cmd.edit(vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
end

--- What the keys do for a diff that owns the tab page it was opened in.
--- @return unidiff.DiffKeys
function M.tab_keys()
  return {
    close = function()
      vim.cmd.quit()
    end,
    goto_file = function(dir)
      M.jump(dir, 'files')
    end,
    before_jump = function()
      vim.cmd.tabclose()
    end,
  }
end

--- @param buf integer
--- @param keys? unidiff.DiffKeys defaults to `tab_keys()`
function M.set(buf, keys)
  keys = vim.tbl_extend('force', M.tab_keys(), keys or {})
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
    keys.goto_file(1)
  end, 'unidiff: next file')
  map('[f', function()
    keys.goto_file(-1)
  end, 'unidiff: previous file')
  map('q', function()
    keys.close()
  end, 'unidiff: close')
  map('<CR>', function()
    M.goto_source(keys.before_jump)
  end, 'unidiff: jump to source line')
end

return M
