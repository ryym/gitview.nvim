--- What the keys do inside a diff buffer.
---
--- Three of them depend on the session the buffer is a pane of: closing gives
--- up the whole session, and moving between files may mean moving the list's
--- cursor. What they call is passed in, so that this module does not depend on
--- the session, as is the repository `gy` names files relative to.
local dlib = require('gitview.diff.lines')
local render = require('gitview.diff.render')
local util = require('gitview.util')

local M = {}

--- @class gitview.DiffKeys
--- @field close fun() what `q` does
--- @field goto_file fun(dir: 1|-1) what `]f` and `[f` do
--- @field open_file fun(path: string, lnum: integer) what `gf` does with the
---        file the cursor is in and the line it stands for
--- @field root string the repository `gy` names files relative to

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

--- `a` alone when the range is one line, `a-b` otherwise.
--- @param lnums integer[] not empty
--- @return string
local function span_of(lnums)
  local first, last = lnums[1], lnums[1]
  for _, n in ipairs(lnums) do
    first, last = math.min(first, n), math.max(last, n)
  end
  return first == last and tostring(first) or ('%d-%d'):format(first, last)
end

--- The last line of a file's new version: the largest number its rows carry,
--- since a view holds every line of the file, folded or not.
--- @param view gitview.View
--- @param file integer
--- @return integer? nil when the new version has no lines
local function last_new_lnum(view, file)
  local last
  for _, l in ipairs(view.lines) do
    if l.file == file and l.new_lnum then
      last = math.max(last or 0, l.new_lnum)
    end
  end
  return last
end

--- Where some rows of one file are, after the file's path.
---
--- The range is in the new version, the file as it is. A deleted row counts as
--- the line that now stands in its place, so selecting across a change widens
--- the range rather than dropping the deleted half of it. Only rows that are all
--- deleted have no place there; they are given in the version they were
--- deleted from, and say so.
---
--- In a mixed view a row may be deleted from the index alone, which HEAD never
--- had. Its number is the index's, and is used only when no row from HEAD is
--- among them: the two count lines differently.
--- @param view gitview.View
--- @param file integer
--- @param rows integer[] rows of the file's lines, none of its header
--- @return string
local function lines_ref(view, file, rows)
  local f = view.files[file]
  local new, old, index = {}, {}, {}
  for _, r in ipairs(rows) do
    local l = view.lines[r]
    if l.new_lnum then
      new[#new + 1] = l.new_lnum
    elseif l.old_lnum then
      old[#old + 1] = l.old_lnum
    else
      index[#index + 1] = l.index_pos
    end
  end
  if #new > 0 then
    -- a deletion at the end of the file stands after its last line
    local last = assert(last_new_lnum(view, file))
    for _, r in ipairs(rows) do
      if not view.lines[r].new_lnum then
        new[#new + 1] = math.min(new_lnum_at(view, r), last)
      end
    end
    return ':' .. span_of(new) .. (f.new_rev and (' (at %s)'):format(f.new_rev) or '')
  end
  if #old > 0 then
    return (':%s (deleted from %s)'):format(span_of(old), f.old_rev or 'the old version')
  end
  return (':%s (deleted from the index)'):format(span_of(index))
end

--- Where the rows `first` to `last` of a diff are, said as text to paste into a
--- message: each file they touch, relative to the repository, and the range of
--- its lines. A file given only by its header row is named without lines, as
--- `gf` opens it at its top. Rows of no file, a commit's header and the blank
--- rows between files, are passed over.
---
--- A file of a commit names the commit, since its line numbers are the commit's
--- and may not be the working tree's any more.
--- @param view gitview.View
--- @param first integer 1-based
--- @param last integer 1-based, at least `first`
--- @param root string the repository the paths are relative to
--- @return string[] one line per file, in the order of the diff
function M.references(view, first, last, root)
  local header_of = {}
  for i, f in ipairs(view.files) do
    header_of[f.row] = i
  end
  local order, rows_of_file = {}, {}
  for r = first, last do
    local l = view.lines[r]
    local file = header_of[r] or (l and dlib.source_kinds[l.kind] and l.file)
    if file then
      if not rows_of_file[file] then
        rows_of_file[file] = {}
        order[#order + 1] = file
      end
      if not header_of[r] then
        table.insert(rows_of_file[file], r)
      end
    end
  end

  local out = {}
  for _, file in ipairs(order) do
    local f = view.files[file]
    local path = vim.fs.relpath(root, f.path) or f.path
    local rows = rows_of_file[file]
    if #rows == 0 then
      out[#out + 1] = path .. (f.new_rev and (' (at %s)'):format(f.new_rev) or '')
    else
      out[#out + 1] = path .. lines_ref(view, file, rows)
    end
  end
  return out
end

--- Put where the rows are into the register the key was given, the unnamed one
--- by default, so that `"+gy` copies them to the clipboard.
--- @param buf integer
--- @param root string
--- @param visual boolean
local function copy_references(buf, root, visual)
  local reg = vim.v.register
  local first = vim.api.nvim_win_get_cursor(0)[1]
  local last = first
  if visual then
    local v = vim.fn.line('v')
    first, last = math.min(v, first), math.max(v, first)
    vim.cmd.normal({ args = { vim.keycode('<Esc>') }, bang = true })
  end
  local view = render.view_of(buf)
  local refs = view and M.references(view, first, last, root) or {}
  if #refs == 0 then
    util.info('no file here')
    return
  end
  vim.fn.setreg(reg, table.concat(refs, '\n'), 'v')
  util.info(#refs == 1 and ('copied %s'):format(refs[1]) or ('copied %d files'):format(#refs))
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
  map('gy', function()
    copy_references(buf, keys.root, false)
  end, 'copy the file and line under the cursor')
  map('gy', function()
    copy_references(buf, keys.root, true)
  end, 'copy the files and lines selected', { 'x' })
end

return M
