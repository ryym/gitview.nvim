--- What the keys do inside a diff buffer.
---
--- Three of them depend on what the buffer is shown in. A diff opened by a
--- command owns its tab page, so closing means closing that tab; the same
--- buffer inside the file list is one pane of something larger, and moving
--- between files means moving the list's cursor. The keys are the same either
--- way, so what they call is passed in rather than branched on here.
local dlib = require('unidiff.diff.lines')
local render = require('unidiff.diff.render')
local util = require('unidiff.util')

local M = {}

--- @class unidiff.DiffKeys
--- @field close fun() what `q` does
--- @field goto_file fun(dir: 1|-1) what `]f` and `[f` do
--- @field before_jump fun() run before `<CR>` opens the file the cursor is in
--- @field open_file fun(path: string, lnum: integer) what `gf` does with the
---        file the cursor is in and the line it stands for

--- The rows of the diff shown in the current window, or nothing when the buffer
--- holds no diff.
--- @param field 'hunk_rows'|'file_rows'
--- @return integer[]
local function rows_of(field)
  local view = render.view_of(vim.api.nvim_get_current_buf())
  return view and view[field] or {}
end

--- Rows are in ascending order, so each direction can stop at the first match:
--- forwards from the start, backwards from the end.
--- @param dir 1|-1
--- @param rows integer[] the rows worth landing on, ascending
function M.jump(dir, rows)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if dir > 0 then
    for _, r in ipairs(rows) do
      if r > cur then
        target = r
        break
      end
    end
  else
    for i = #rows, 1, -1 do
      if rows[i] < cur then
        target = rows[i]
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

--- Move between the file headers of a multi-file diff, which is what `]f` means
--- when the whole diff is in one buffer.
--- @param dir 1|-1
function M.jump_files(dir)
  M.jump(dir, rows_of('file_rows'))
end

--- Open the file the cursor's row came from, at the line it stands for.
--- @param before_jump fun() gives up whatever the diff was being shown in
function M.goto_source(before_jump)
  local buf = vim.api.nvim_get_current_buf()
  local view = render.view_of(buf)
  if not view then
    return
  end
  -- Both sides of a historical view are committed versions, so its line
  -- numbers name lines of the commit rather than of the file on disk. Jumping
  -- would land on whatever now occupies that line, or on a file the working
  -- tree no longer has.
  if view.historical then
    util.warn('this diff is between commits; there is no working-tree line to jump to')
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

--- The line of the new version a row lands on.
---
--- A row the new version has is its own line. One it lacks — a deleted line, or
--- in a mixed view an index line the working tree dropped — lands on the line
--- that now stands where it was: the one after the nearest row above it that the
--- new version has.
--- @param view unidiff.View
--- @param row integer 1-based, a row of a source kind
--- @return integer lnum
local function new_lnum_at(view, row)
  local l = view.lines[row]
  if l.new_lnum then
    return l.new_lnum
  end
  for r = row - 1, 1, -1 do
    local above = view.lines[r]
    if above.file ~= l.file then
      break
    end
    if above.new_lnum then
      return above.new_lnum + 1
    end
  end
  return 1
end

--- The file a row of the diff belongs to, and the line of it to open at.
---
--- A file's header, and the blank row that parts it from the next file, open the
--- file at its top. The rows of a commit's header come before any file and
--- belong to none.
--- @param view unidiff.View
--- @param row integer 1-based
--- @return string? path absolute
--- @return integer? lnum
function M.source_at(view, row)
  for _, f in ipairs(view.files) do
    if f.row == row then
      return f.path, 1
    end
  end
  for r = row, 1, -1 do
    local l = view.lines[r]
    if l and l.file then
      local path = view.files[l.file].path
      if r ~= row then
        return path, 1
      end
      return path, new_lnum_at(view, row)
    end
  end
  return nil, nil
end

--- Edit a file in the current window and put the cursor on a line of it.
---
--- The line is clamped to the file: a line number taken from a commit can be
--- past the end of the file as it is now.
--- @param path string
--- @param lnum integer
function M.edit_at(path, lnum)
  if vim.fn.bufnr(path) ~= vim.api.nvim_get_current_buf() then
    vim.cmd.edit(vim.fn.fnameescape(path))
  end
  -- `:edit` records the jump by itself, but not when the file was already here.
  vim.cmd("normal! m'")
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(lnum, last)), 0 })
end

--- What the keys do for a diff that owns the tab page it was opened in.
--- @return unidiff.DiffKeys
function M.tab_keys()
  return {
    close = function()
      vim.cmd.quit()
    end,
    goto_file = M.jump_files,
    before_jump = function()
      vim.cmd.tabclose()
    end,
    open_file = function(path, lnum)
      vim.cmd.tabclose()
      M.edit_at(path, lnum)
    end,
  }
end

--- @param buf integer
--- @param keys? unidiff.DiffKeys defaults to `tab_keys()`
function M.set(buf, keys)
  keys = vim.tbl_extend('force', M.tab_keys(), keys or {})
  local map = util.buf_mapper(buf)
  map(']h', function()
    M.jump(1, rows_of('hunk_rows'))
  end, 'next hunk')
  map('[h', function()
    M.jump(-1, rows_of('hunk_rows'))
  end, 'previous hunk')
  map(']f', function()
    keys.goto_file(1)
  end, 'next file')
  map('[f', function()
    keys.goto_file(-1)
  end, 'previous file')
  map('q', function()
    keys.close()
  end, 'close')
  map('<CR>', function()
    M.goto_source(keys.before_jump)
  end, 'jump to source line')
  map('gf', function()
    local view = render.view_of(buf)
    local path, lnum = nil, nil
    if view then
      path, lnum = M.source_at(view, vim.api.nvim_win_get_cursor(0)[1])
    end
    if not path then
      util.info('no file here')
      return
    end
    keys.open_file(path, lnum)
  end, 'open the file the cursor is in')
end

return M
