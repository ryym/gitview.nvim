--- What the keys do inside a diff buffer.
---
--- Three of them depend on the session the buffer is a pane of: closing gives
--- up the whole session, and moving between files may mean moving the list's
--- cursor. What they call is passed in, so that this module does not depend on
--- the session.
local render = require('gitview.diff.render')
local util = require('gitview.util')

local M = {}

--- @class gitview.DiffKeys
--- @field close fun() what `q` does
--- @field goto_file fun(dir: 1|-1) what `]f` and `[f` do
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

--- The line of the new version a row lands on.
---
--- A row the new version has is its own line. One it lacks — a deleted line, or
--- in a mixed view an index line the working tree dropped — lands on the line
--- that now stands where it was: the one after the nearest row above it that the
--- new version has.
--- @param view gitview.View
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
--- @param view gitview.View
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

--- @param buf integer
--- @param keys gitview.DiffKeys
function M.set(buf, keys)
  local map = util.buf_mapper(buf)
  map(']c', function()
    M.jump(1, rows_of('hunk_rows'))
  end, 'next hunk')
  map('[c', function()
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
