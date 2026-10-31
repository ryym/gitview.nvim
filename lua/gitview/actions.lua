--- What can be done to an open session, one function per action, for mapping
--- keys to. The default keys are mapped to these as well; see `gitview.keymaps`.
---
--- An action works on the session of the current tab page, in the pane the
--- cursor is in, which is told by the current buffer. One that means nothing in
--- that pane, or is called with no session, returns false.
---
--- Every action returns whether it did anything, a message saying why it could
--- not included; false means nothing happened and nothing was said, so a caller
--- is free to do something else with the key. Whatever the action sets off may
--- still be under way when it returns: re-reading the status after staging is.
---
--- These are the plugin's interface, so they wrap the session's functions
--- rather than hand them out: the session is free to change its own.
---
--- Nothing heavy is required at the top, since this is required from the
--- user's configuration before any session is opened.
local util = require('gitview.util')

local M = {}

--- @alias gitview.Pane 'files'|'commits'|'diff'

--- The session of the current tab page, and the pane of it the cursor is in.
---
--- The pane is told by the buffer rather than by its filetype, which a buffer
--- that is no pane could have too, and which a pane could be given another of.
--- @return gitview.Session?
--- @return gitview.Pane? nil in a window of the tab page that is no pane
local function current_pane()
  local s = require('gitview.ui.session').current()
  if not s then
    return nil, nil
  end
  local buf = vim.api.nvim_get_current_buf()
  local pane = (buf == s.files_buf and 'files')
    or (buf == s.commits_buf and 'commits')
    or (buf == s.diff_buf and 'diff')
    or nil
  return s, pane
end

--- @return boolean
local function in_visual()
  local mode = vim.fn.mode()
  return mode == 'v' or mode == 'V' or mode == '\22'
end

local function leave_visual()
  if in_visual() then
    vim.cmd.normal({ args = { vim.keycode('<Esc>') }, bang = true })
  end
end

--- The rows the action is to take: those selected in visual mode, or the
--- cursor's alone. The ends of a selection are read before leaving it, since
--- the marks that would give them afterwards are only set on the way out.
---
--- This is why such an action has to be mapped to a function or to `<Cmd>`: a
--- mapping going through the command line has left visual mode before it runs.
--- @return integer first
--- @return integer last
local function selected_rows()
  local row = vim.fn.line('.')
  if not in_visual() then
    return row, row
  end
  local v = vim.fn.line('v')
  leave_visual()
  return math.min(v, row), math.max(v, row)
end

--- The session and the pane, when the cursor is in one of `panes`. Visual mode
--- is left as it is, for an action taking what is selected.
--- @param panes table<gitview.Pane, true>
--- @return gitview.Session?
--- @return gitview.Pane?
local function in_panes(panes)
  local s, pane = current_pane()
  if not (s and pane and panes[pane]) then
    return nil, nil
  end
  return s, pane
end

--- As `in_panes`, out of visual mode, for an action that takes no selection.
--- @param panes table<gitview.Pane, true>
--- @return gitview.Session?
--- @return gitview.Pane?
local function at_cursor(panes)
  local s, pane = in_panes(panes)
  if s then
    leave_visual()
  end
  return s, pane
end

--- The session, for an action on the whole of it, which works from any window
--- of its tab page.
--- @return gitview.Session?
local function whole()
  local s = current_pane()
  if s then
    leave_visual()
  end
  return s
end

local LISTS = { files = true, commits = true }
local ALL = { files = true, commits = true, diff = true }

--- Focus the diff pane.
--- @return boolean
function M.focus_diff()
  local s = at_cursor(LISTS)
  if not s then
    return false
  end
  vim.api.nvim_set_current_win(s.diff_win)
  return true
end

--- Look into the commit, or the range, under the cursor: its files replace the
--- commits pane. On the working tree the files pane is focused instead.
--- @return boolean false when already looking into one, or on no commit
function M.look_into()
  local s = at_cursor({ commits = true })
  return s ~= nil and require('gitview.ui.session').enter(s)
end

--- Stop looking into a commit.
--- @return boolean false when nothing is being looked into
function M.back_out()
  local s = at_cursor({ commits = true })
  return s ~= nil and require('gitview.ui.session').leave(s)
end

--- Review the commit or range under the cursor, or the one being looked into.
--- @return boolean
function M.start_review()
  local s, pane = at_cursor({ files = true, commits = true })
  if not s then
    return false
  end
  if pane == 'files' then
    util.info('a review is started from the commits pane')
    return true
  end
  return require('gitview.ui.session').start_review(s)
end

--- End the review, asking first if it is part way through.
--- @return boolean false when there is no review
function M.end_review()
  local s = at_cursor({ files = true })
  return s ~= nil and require('gitview.ui.session').end_review(s)
end

--- Make the commit under the cursor the far end of a range, whose near end is
--- wherever the cursor goes.
--- @return boolean false on no commit
function M.start_range()
  local s = at_cursor({ commits = true })
  return s ~= nil and require('gitview.ui.session').set_mark(s)
end

--- @return boolean false when there is no range
function M.clear_range()
  local s = at_cursor({ commits = true })
  return s ~= nil and require('gitview.ui.session').clear_mark(s)
end

--- Check off the files under review selected or under the cursor, in the files
--- pane or in the diff, which then goes on to the next one to read. Their
--- checks are taken off when all are checked.
--- @return boolean
function M.toggle_check()
  local s, pane = in_panes(ALL)
  if not s then
    return false
  end
  local session = require('gitview.ui.session')
  if pane == 'files' then
    return session.check_rows(s, selected_rows())
  end
  if pane == 'diff' then
    session.check_shown(s, selected_rows())
    return true
  end
  leave_visual()
  util.info(s.review and 'the files under review are in the files pane'
    or 'files are checked off during a review')
  return true
end

--- @param dir 1|-1
--- @return boolean
local function step_unread(dir)
  local s, pane = at_cursor({ files = true, diff = true })
  if not s then
    return false
  end
  local session = require('gitview.ui.session')
  if pane == 'files' then
    session.step_listed_open(s, vim.api.nvim_get_current_win(), dir)
  else
    session.step_open(s, dir)
  end
  return true
end

--- Go to the next file under review still to be read, going round from the
--- other end. In the files pane, the list's cursor moves there and the focus
--- stays.
--- @return boolean
function M.next_unread()
  return step_unread(1)
end

--- @return boolean
function M.prev_unread()
  return step_unread(-1)
end

--- @param op 'stage'|'unstage'
--- @return boolean
local function apply(op)
  local s, pane = in_panes(ALL)
  if not s then
    return false
  end
  local session = require('gitview.ui.session')
  if pane == 'diff' then
    return session.apply_to_rows(s, op, selected_rows())
  end
  if pane == 'files' then
    return session.apply_to_list_rows(s, op, selected_rows())
  end
  leave_visual()
  util.info('only an uncommitted file can be staged')
  return true
end

--- Stage the files or directories selected or under the cursor in the files
--- pane, or the lines selected or under the cursor in the diff.
--- @return boolean
function M.stage()
  return apply('stage')
end

--- @return boolean
function M.unstage()
  return apply('unstage')
end

--- @param op 'stage'|'unstage'
--- @return boolean
local function apply_hunk(op)
  local s = at_cursor({ diff = true })
  return s ~= nil and require('gitview.ui.session').apply_to_hunk(s, op)
end

--- Stage the whole change the diff's cursor is in.
--- @return boolean
function M.stage_hunk()
  return apply_hunk('stage')
end

--- @return boolean
function M.unstage_hunk()
  return apply_hunk('unstage')
end

--- @param dir 1|-1
--- @return boolean
local function step_file(dir)
  local s, pane = at_cursor(ALL)
  if not s then
    return false
  end
  local session = require('gitview.ui.session')
  if pane == 'diff' then
    return session.step_file(s, dir)
  end
  return session.step_listed_file(s, vim.api.nvim_get_current_win(), dir)
end

--- Go to the next file. In a list, the cursor moves to the next row of a file,
--- passing over directories; in the commits pane, only among the files of a
--- commit being looked into. In the diff, a diff of many files moves to the
--- next one's header, and any other the list's cursor to the next file, shown
--- in the diff.
--- @return boolean false when there is no next file
function M.next_file()
  return step_file(1)
end

--- @return boolean
function M.prev_file()
  return step_file(-1)
end

--- @param dir 1|-1
--- @return boolean
local function step_commit(dir)
  local s = at_cursor({ diff = true })
  if not s then
    return false
  end
  require('gitview.ui.session').step_commit(s, dir)
  return true
end

--- Show the next commit of the list, the older one, without leaving the diff.
--- @return boolean
function M.next_commit()
  return step_commit(1)
end

--- Show the previous commit of the list, the newer one.
--- @return boolean
function M.prev_commit()
  return step_commit(-1)
end

--- @param dir 1|-1
--- @return boolean
local function step_hunk(dir)
  local s = at_cursor({ diff = true })
  return s ~= nil and require('gitview.diff.keymap').jump_hunks(dir)
end

--- @return boolean false when there is no next change
function M.next_hunk()
  return step_hunk(1)
end

--- @return boolean false when there is no previous change
function M.prev_hunk()
  return step_hunk(-1)
end

--- Open the file under the cursor in the tab page the session was opened
--- from; from the diff, at the line the cursor is on.
--- @return boolean
function M.open_file()
  local s, pane = at_cursor(ALL)
  if not s then
    return false
  end
  local session = require('gitview.ui.session')
  if pane == 'diff' then
    session.open_shown(s)
  else
    session.open_listed(s, vim.api.nvim_get_current_win())
  end
  return true
end

--- Copy the files and lines selected or under the cursor in the diff, as text
--- to paste into a message, into the register the key was given, the unnamed
--- one by default, so that `"+gy` copies them to the clipboard.
--- @return boolean
function M.copy_location()
  local s = in_panes({ diff = true })
  if not s then
    return false
  end
  -- Read before leaving visual mode, which resets it.
  local reg = vim.v.register
  local first, last = selected_rows()
  require('gitview.diff.keymap').copy_references(s.diff_buf, s.root, first, last, reg)
  return true
end

--- Start counting lines that differ only in whitespace as changed again, or
--- stop.
--- @return boolean
function M.toggle_ignore_whitespace()
  local s = whole()
  if not s then
    return false
  end
  require('gitview.ui.session').toggle_whitespace(s)
  return true
end

--- Show the next layer of the uncommitted changes: both, staged alone, or
--- unstaged alone, and round again.
--- @return boolean
function M.cycle_layer()
  local s = whole()
  if not s then
    return false
  end
  require('gitview.ui.session').toggle_layer(s)
  return true
end

--- Re-read the repository. The panes are redrawn once it has been read.
--- @return boolean
function M.refresh()
  local s = whole()
  if not s then
    return false
  end
  require('gitview.ui.session').refresh(s)
  return true
end

--- Close the session, asking first if that throws away a review part way
--- through, unless `force`.
--- @param opts? {force?: boolean}
--- @return boolean
function M.close(opts)
  local s = whole()
  if not s then
    return false
  end
  local session = require('gitview.ui.session')
  if opts and opts.force then
    session.close(s)
  else
    session.close_asked(s)
  end
  return true
end

return M
