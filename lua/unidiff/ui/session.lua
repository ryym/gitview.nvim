--- One tab page showing a repository's uncommitted changes: the file list on
--- the left, the selected file's diff on the right.
---
--- The session is what makes this different from the diff commands: those
--- render a snapshot and forget it, while this keeps enough state to be redrawn
--- when the repository changes underneath it, and to follow the cursor from one
--- file to the next.
local config = require('unidiff.config')
local git = require('unidiff.git')
local index = require('unidiff.index')
local keymap = require('unidiff.diff.keymap')
local list = require('unidiff.ui.list')
local render = require('unidiff.diff.render')
local source = require('unidiff.diff.source')
local stage = require('unidiff.stage')
local status = require('unidiff.status')
local util = require('unidiff.util')
local vlib = require('unidiff.diff.view')

local M = {}

--- @class unidiff.Session
--- @field tab integer tab page handle
--- @field root string repository root, resolved once
--- @field list_win integer
--- @field list_buf integer
--- @field diff_win integer
--- @field diff_buf integer drawn into repeatedly, never swapped out
--- @field entries unidiff.StatusEntry[]
--- @field selected integer? index of the entry the diff pane is showing
--- @field has_head boolean whether the repository has a commit; re-read on refresh
--- @field index_lines string[]? the selected file's index contents, for staging
---        part of it; nil whenever the pane shows a notice instead of a diff

--- @type table<integer, unidiff.Session>
M.sessions = {}

--- @return unidiff.Session?
function M.current()
  return M.sessions[vim.api.nvim_get_current_tabpage()]
end

--- What the diff pane compares. Unlike the diff commands there is no choice of
--- revision here: the point of the view is what has not been committed.
local REV = 'HEAD, staged + unstaged'

--- Draw the selected entry, or say why there is nothing to draw.
---
--- The index contents are kept, because the drawn rows cannot stand in for them:
--- a view is trimmed, so everything away from a change has been folded into a
--- `gap` row and is no longer there to be read back.
---
--- @param s unidiff.Session
function M.show_selected(s)
  s.index_lines = nil
  local entry = s.entries[s.selected or 0]
  if not entry then
    render.notice(s.diff_buf, list.EMPTY_NOTICE)
    return
  end
  if entry.binary then
    render.notice(s.diff_buf, ('%s   (binary file)'):format(status.label(entry)))
    return
  end
  -- An unmerged path holds the three merge stages and no stage 0, so there is no
  -- index version to build the middle of a mixed view from.
  if entry.conflicted then
    render.notice(s.diff_buf, ('%s   (unresolved conflict)'):format(status.label(entry)))
    return
  end

  local src = source.for_entry(entry, s.root)
  local view = src
    and vlib.build({ src }, REV, config.values.context, config.diff_opts(config.values))
  if not view then
    -- a pure rename or a mode change: a real change with no lines to show
    render.notice(s.diff_buf, ('%s   (no textual change)'):format(status.label(entry)))
    return
  end
  view.mixed = true
  render.draw(s.diff_buf, view)
  vlib.dispose(view)
  s.index_lines = src.index_lines
end

--- Draw whatever the list's cursor is on.
---
--- Following the cursor means skipping the work when it has not left the row it
--- was on, but the first draw and a refresh have to happen regardless: both can
--- leave the selection exactly where it was and still need the pane rebuilt.
---
--- @param s unidiff.Session
--- @param force boolean? draw even when the selection has not moved
local function sync_selection(s, force)
  local row = vim.api.nvim_win_get_cursor(s.list_win)[1]
  local index = list.index_at(s.list_buf, row)
  if force or index ~= s.selected then
    s.selected = index
    M.show_selected(s)
  end
end

--- Put the list's cursor on an entry and show it. An index past either end is
--- clamped, so `]f` on the last file stays on the last file.
--- @param s unidiff.Session
--- @param index integer
function M.select(s, index)
  if #s.entries == 0 then
    return
  end
  index = math.max(1, math.min(#s.entries, index))
  local row = list.row_of(s.list_buf, index)
  if row then
    vim.api.nvim_win_set_cursor(s.list_win, { row, 0 })
  end
  if index ~= s.selected then
    s.selected = index
    M.show_selected(s)
  end
end

--- Re-read the repository and redraw both panes.
--- @param s unidiff.Session
function M.refresh(s)
  local entries, err = status.list(s.root)
  if not entries then
    util.git_error(err)
    return
  end
  s.entries = entries
  -- Re-read rather than kept from `open`: the first commit can be made while
  -- the session is open, and it is one process against the several `status.list`
  -- already spends.
  s.has_head = git.has_head(s.root)
  list.draw(s.list_buf, s.root, entries)

  -- The list is usually shorter after a refresh, not longer, so the cursor can
  -- be past the end of what was just drawn.
  local row = vim.api.nvim_win_get_cursor(s.list_win)[1]
  local last = vim.api.nvim_buf_line_count(s.list_buf)
  if row > last then
    vim.api.nvim_win_set_cursor(s.list_win, { last, 0 })
  end

  -- The row under the cursor may now be a different file, or the same file with
  -- different contents, so the diff is rebuilt either way.
  sync_selection(s, true)
end

--- @param s unidiff.Session
function M.close(s)
  if not vim.api.nvim_tabpage_is_valid(s.tab) then
    return
  end
  -- `tabclose` refuses when it is the only tab page; there is nothing to go
  -- back to then, so the windows are closed instead.
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(s.tab)
    vim.cmd.tabclose()
  else
    vim.api.nvim_win_close(s.diff_win, true)
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

--- Change the index for the file under the cursor, then redraw.
---
--- Both panes are rebuilt from git rather than adjusted in place: the status
--- letters, the file's three versions and which lines count as staged all move
--- together, and re-reading is what keeps them agreeing.
---
--- The cursor is left on the row it was on. Staging or unstaging never removes a
--- file from the list — it still differs from HEAD either way — and the list is
--- ordered by path, so the row goes on meaning the same file.
---
--- @param s unidiff.Session
--- @param decide fun(e: unidiff.StatusEntry, has_head: boolean): unidiff.StageAction?, string?
local function apply_to_selected(s, decide)
  local entry = s.entries[s.selected or 0]
  if not entry then
    return
  end
  local action, why = decide(entry, s.has_head)
  if not action then
    util.info(why or 'nothing to do')
    return
  end
  local err = stage.run(action, s.root)
  if err then
    util.git_error(err)
    return
  end
  M.refresh(s)
end

--- Move some of the selected file's rows across the index, then redraw.
---
--- The rows on display are the operation's whole input: each one says which
--- layer it belongs to and where it sits in the index, so a range of rows is
--- enough to state what to write. Which rows those are — one, a visual
--- selection, a hunk — is the caller's business.
---
--- @param s unidiff.Session
--- @param op 'stage'|'unstage'
--- @param first integer 1-based row of the diff buffer
--- @param last integer inclusive
local function apply_to_rows(s, op, first, last)
  local entry = s.entries[s.selected or 0]
  local view = render.views[s.diff_buf]
  if not entry or not view or not s.index_lines then
    return
  end
  -- A backstop, not the guard that fires today: `show_selected` draws a notice
  -- for a conflicted entry, so no view and no index contents exist to get here
  -- with. It stays because writing a stage-0 entry over a conflict's merge stages
  -- discards them and git reports no error, so anything that later makes such a
  -- file renderable would silently reopen that.
  if entry.conflicted then
    util.warn(('%s has an unresolved conflict; resolve it first'):format(entry.path))
    return
  end
  local rows = index.selection(view.lines, first, last, op)
  if #rows == 0 then
    util.info(('nothing to %s here'):format(op))
    return
  end
  local err = index.write(op, entry, index.apply(s.index_lines, rows), s.root)
  if err then
    util.git_error(err)
    return
  end
  M.refresh(s)
end

--- The rows a key pressed in the diff pane acts on.
---
--- In visual mode the two ends of the selection are read before leaving it,
--- since the marks that would give them afterwards are only set on the way out.
--- @param visual boolean
--- @return integer first
--- @return integer last
local function pressed_rows(visual)
  if not visual then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    return row, row
  end
  local a, b = vim.fn.line('v'), vim.fn.line('.')
  vim.cmd.normal({ args = { vim.keycode('<Esc>') }, bang = true })
  return math.min(a, b), math.max(a, b)
end

--- Inside the diff, `s` and `u` work on lines rather than on the whole file:
--- the rows under the cursor or the visual selection, and with a capital, the
--- whole change the cursor is in.
--- @param s unidiff.Session
local function set_diff_stage_keymaps(s)
  for _, op in ipairs({ 'stage', 'unstage' }) do
    local lhs = op == 'stage' and 's' or 'u'
    for _, mode in ipairs({ 'n', 'x' }) do
      vim.keymap.set(mode, lhs, function()
        apply_to_rows(s, op, pressed_rows(mode == 'x'))
      end, { buffer = s.diff_buf, desc = ('unidiff: %s the selected lines'):format(op) })
    end
    vim.keymap.set('n', lhs:upper(), function()
      local view = render.views[s.diff_buf]
      local first, last = index.hunk_at(view and view.lines or {}, vim.fn.line('.'))
      if not first then
        util.info('not inside a change')
        return
      end
      apply_to_rows(s, op, first, last)
    end, { buffer = s.diff_buf, desc = ('unidiff: %s this hunk'):format(op) })
  end
end

--- @param s unidiff.Session
local function set_list_keymaps(s)
  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = s.list_buf, desc = desc })
  end
  map('<CR>', function()
    vim.api.nvim_set_current_win(s.diff_win)
  end, 'unidiff: focus the diff')
  -- `s` and `u` rather than one key toggling: a file with changes on both sides
  -- has no obvious sense in which it is on or off, and a row here states that
  -- state rather than hiding it, so the direction is given explicitly.
  map('s', function()
    apply_to_selected(s, stage.stage)
  end, 'unidiff: stage the file under the cursor')
  map('u', function()
    apply_to_selected(s, stage.unstage)
  end, 'unidiff: unstage the file under the cursor')
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

--- Inside a session a diff is one pane of something larger: `q` gives up the
--- whole session, and moving between files means moving the list's cursor
--- rather than scrolling within one buffer.
--- @param s unidiff.Session
local function set_diff_keymaps(s)
  keymap.set(s.diff_buf, {
    close = function()
      M.close(s)
    end,
    goto_file = function(dir)
      M.select(s, (s.selected or 1) + dir)
      vim.api.nvim_set_current_win(s.list_win)
    end,
    before_jump = function()
      M.close(s)
    end,
  })
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
    diff_buf = render.create_buffer(),
    entries = entries,
    has_head = git.has_head(root),
  }
  vim.api.nvim_win_set_buf(s.list_win, s.list_buf)
  -- An explicit side, rather than `:vsplit`, which follows 'splitright'.
  s.diff_win = vim.api.nvim_open_win(s.diff_buf, false, {
    split = 'right',
    win = s.list_win,
  })

  list.draw(s.list_buf, root, entries)
  list.configure_window(s.list_win, config.values.list_width)
  render.configure_window(s.diff_win, s.diff_buf)
  set_list_keymaps(s)
  set_diff_keymaps(s)
  set_diff_stage_keymaps(s)

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = s.list_buf,
    callback = function()
      sync_selection(s)
    end,
  })

  M.sessions[s.tab] = s
  vim.api.nvim_create_autocmd('TabClosed', {
    group = vim.api.nvim_create_augroup('unidiff.ui.session.' .. s.tab, { clear = true }),
    callback = function()
      -- TabClosed does not say which tab went, so this checks its own.
      if not vim.api.nvim_tabpage_is_valid(s.tab) then
        M.sessions[s.tab] = nil
        for _, buf in ipairs({ s.list_buf, s.diff_buf }) do
          if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
          end
        end
        return true -- delete the autocommand
      end
    end,
  })

  sync_selection(s, true)
  return s
end

return M
