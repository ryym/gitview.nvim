--- One tab page showing a repository's uncommitted changes.
---
--- The session is what makes this different from the diff commands: those
--- render a snapshot and forget it, while this keeps enough state to be redrawn
--- when the repository changes underneath it.
local list = require('unidiff.ui.list')
local source = require('unidiff.diff.source')
local status = require('unidiff.status')
local util = require('unidiff.util')

local M = {}

--- @class unidiff.Session
--- @field tab integer tab page handle
--- @field root string repository root, resolved once
--- @field list_win integer
--- @field list_buf integer
--- @field entries unidiff.StatusEntry[]

--- @type table<integer, unidiff.Session>
M.sessions = {}

--- @return unidiff.Session?
function M.current()
  return M.sessions[vim.api.nvim_get_current_tabpage()]
end

--- Re-read the repository and redraw the list, keeping the cursor where it is.
--- @param s unidiff.Session
function M.refresh(s)
  local entries, err = status.list(s.root)
  if not entries then
    util.git_error(err)
    return
  end
  s.entries = entries
  list.draw(s.list_buf, s.root, entries)

  -- The list is usually shorter after a refresh, not longer, so the cursor can
  -- be past the end of what was just drawn.
  local row = vim.api.nvim_win_get_cursor(s.list_win)[1]
  local last = vim.api.nvim_buf_line_count(s.list_buf)
  if row > last then
    vim.api.nvim_win_set_cursor(s.list_win, { last, 0 })
  end
end

--- @param s unidiff.Session
function M.close(s)
  if not vim.api.nvim_tabpage_is_valid(s.tab) then
    return
  end
  -- `tabclose` refuses when it is the only tab page; there is nothing to go
  -- back to then, so the window is closed instead.
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(s.tab)
    vim.cmd.tabclose()
  else
    vim.cmd.quit()
  end
end

--- Open the file under the cursor in place of the session.
--- @param s unidiff.Session
function M.edit_entry(s)
  local row = vim.api.nvim_win_get_cursor(s.list_win)[1]
  local entry = list.entry_at(s.list_buf, row)
  if not entry then
    return
  end
  local path = s.root .. '/' .. entry.path
  if vim.fn.filereadable(path) == 0 then
    util.warn(('%s is not in the working tree'):format(entry.path))
    return
  end
  M.close(s)
  vim.cmd.edit(vim.fn.fnameescape(path))
end

--- @param s unidiff.Session
local function set_keymaps(s)
  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = s.list_buf, desc = desc })
  end
  map('R', function()
    M.refresh(s)
  end, 'unidiff: refresh the list')
  map('o', function()
    M.edit_entry(s)
  end, 'unidiff: edit the file under the cursor')
  map('q', function()
    M.close(s)
  end, 'unidiff: close')
end

--- Open a tab page listing everything uncommitted.
--- @return unidiff.Session?
function M.open()
  local root = source.repo_root()
  if not root then
    return
  end
  local entries, err = status.list(root)
  if not entries then
    util.git_error(err)
    return
  end

  vim.cmd.tabnew()
  local s = { --- @type unidiff.Session
    tab = vim.api.nvim_get_current_tabpage(),
    root = root,
    list_win = vim.api.nvim_get_current_win(),
    list_buf = list.create_buffer(),
    entries = entries,
  }
  vim.api.nvim_win_set_buf(s.list_win, s.list_buf)
  list.draw(s.list_buf, root, entries)
  list.configure_window(s.list_win)
  set_keymaps(s)

  M.sessions[s.tab] = s
  vim.api.nvim_create_autocmd('TabClosed', {
    group = vim.api.nvim_create_augroup('unidiff.ui.session.' .. s.tab, { clear = true }),
    callback = function()
      -- TabClosed does not say which tab went, so this checks its own.
      if not vim.api.nvim_tabpage_is_valid(s.tab) then
        M.sessions[s.tab] = nil
        if vim.api.nvim_buf_is_valid(s.list_buf) then
          vim.api.nvim_buf_delete(s.list_buf, { force = true })
        end
        return true -- delete the autocommand
      end
    end,
  })
  return s
end

return M
