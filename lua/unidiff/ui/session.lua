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
--- @field commits unidiff.Commit[] the tail of the history, newest first
--- @field scope unidiff.ListScope? the commit being looked into, whose files
---        replace the list while it is set
--- @field selected unidiff.ListTarget? what the diff pane is showing
--- @field generation integer bumped by every draw, so a deferred one can tell
---        whether it is still wanted
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

--- The commit list, or nothing when there is no HEAD to read one from.
---
--- `git log` fails outright in a repository with no commit rather than printing
--- an empty log, so the question has to be asked before the command is run.
--- @param s unidiff.Session
--- @return unidiff.Commit[]
local function read_commits(s)
  if not s.has_head then
    return {}
  end
  local commits, err = git.log(config.values.commit_count, s.root)
  if not commits then
    util.git_error({ what = 'git log', stderr = err or '' })
    return {}
  end
  return commits
end

--- Draw one commit against its first parent.
---
--- This is a two-version view, the shape `:UnidiffAll` already produces: there
--- is no index between the sides and so nothing to mark as staged.
--- @param s unidiff.Session
--- @param commit unidiff.Commit?
local function show_commit(s, commit)
  if not commit then
    render.notice(s.diff_buf, list.EMPTY_NOTICE)
    return
  end
  local label = ('%s %s'):format(commit.sha, commit.subject)
  local sources, skipped, err = source.for_commit(commit, s.root)
  if not sources then
    util.git_error(err)
    render.notice(s.diff_buf, label .. '   (could not be read)')
    return
  end

  local view, unchanged =
    vlib.build(sources, commit.sha, config.values.context, config.diff_opts(config.values))
  if not view then
    render.notice(s.diff_buf, label .. '   (no textual change)')
    return
  end
  -- Its line numbers are the commit's, not the working tree's, so jumping to
  -- the source would land on whatever now occupies that line.
  view.historical = true
  view.note = vlib.skipped_note(skipped, #unchanged)
  if #commit.parents > 1 then
    view.note = (view.note and view.note .. '   ' or '') .. '(first parent)'
  end
  render.draw(s.diff_buf, view)
  vlib.dispose(view)
end

--- Draw one file of the commit being looked into.
---
--- This is the same two-version view `show_commit` draws, narrowed to one file:
--- one entry of the change list the scope already holds, so nothing has to be
--- listed again.
--- @param s unidiff.Session
--- @param index integer into the scope's changes
local function show_commit_file(s, index)
  local scope = s.scope
  local change = scope and scope.changes[index]
  if not scope or not change then
    render.notice(s.diff_buf, list.EMPTY_NOTICE)
    return
  end
  local label = status.change_label(change)
  if change.binary then
    render.notice(s.diff_buf, ('%s   (binary file)'):format(label))
    return
  end

  local src = source.for_commit_change(scope.commit, change, s.root)
  local view = src
    and vlib.build(
      { src },
      scope.commit.sha,
      config.values.context,
      config.diff_opts(config.values)
    )
  if not view then
    -- a pure rename or a mode change: a real change with no lines to show
    render.notice(s.diff_buf, ('%s   (no textual change)'):format(label))
    return
  end
  view.historical = true
  render.draw(s.diff_buf, view)
  vlib.dispose(view)
end

--- Draw whatever is selected, or say why there is nothing to draw.
---
--- The index contents are kept, because the drawn rows cannot stand in for them:
--- a view is trimmed, so everything away from a change has been folded into a
--- `gap` row and is no longer there to be read back.
---
--- @param s unidiff.Session
function M.show_selected(s)
  s.index_lines = nil
  local target = s.selected
  if not target then
    render.notice(s.diff_buf, list.EMPTY_NOTICE)
    return
  end
  if target.kind == 'commit' then
    show_commit(s, s.commits[target.index])
    return
  end
  if target.kind == 'commit_file' then
    show_commit_file(s, target.index)
    return
  end

  local entry = s.entries[target.index]
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
--- How long a commit row has to keep the cursor before its diff is built.
---
--- A commit's diff is every file it touched, so building one per `CursorMoved`
--- would run the whole pipeline once for each row passed over on the way
--- somewhere. A file row costs a single file's view and is still drawn at once.
local COMMIT_DELAY_MS = 60

--- @param s unidiff.Session
--- @param force boolean? draw even when the selection has not moved
local function sync_selection(s, force)
  local row = vim.api.nvim_win_get_cursor(s.list_win)[1]
  local target = list.target_at(s.list_buf, row)
  if not force and list.same_target(target, s.selected) then
    return
  end
  s.selected = target
  -- Every draw takes a generation, so a deferred one can tell that it is no
  -- longer wanted without a timer handle to cancel.
  s.generation = s.generation + 1

  -- A refresh is an explicit act rather than a cursor sweep, so it is not
  -- worth delaying even when a commit is selected.
  if force or not target or target.kind ~= 'commit' then
    M.show_selected(s)
    return
  end
  local generation = s.generation
  vim.defer_fn(function()
    if s.generation == generation and vim.api.nvim_buf_is_valid(s.diff_buf) then
      M.show_selected(s)
    end
  end, COMMIT_DELAY_MS)
end

--- Put the list's cursor on the nth file it lists and show it. An index past
--- either end is clamped, so `]f` on the last file stays on the last file.
---
--- Which list that is depends on where the session is: the uncommitted changes,
--- or the files of the commit being looked into.
--- @param s unidiff.Session
--- @param kind 'file'|'commit_file'
--- @param index integer
local function select_nth(s, kind, index)
  local count = kind == 'file' and #s.entries or #(s.scope and s.scope.changes or {})
  if count == 0 then
    return
  end
  index = math.max(1, math.min(count, index))
  local target = { kind = kind, index = index } --- @type unidiff.ListTarget
  local row = list.row_of(s.list_buf, target)
  if row then
    vim.api.nvim_win_set_cursor(s.list_win, { row, 0 })
  end
  if not list.same_target(target, s.selected) then
    s.selected = target
    s.generation = s.generation + 1
    M.show_selected(s)
  end
end

--- Put the list's cursor on one of the uncommitted files and show it.
--- @param s unidiff.Session
--- @param index integer
function M.select(s, index)
  select_nth(s, 'file', index)
end

--- What the selection names, in terms that survive a redraw.
---
--- Neither the row nor the index into a list can be used to find the same thing
--- again: the file section changes length, which moves every commit row below
--- it, and a file removed from the list shifts the indices of the rest.
---
--- @alias unidiff.SelectionId {kind:'file'|'commit'|'commit_file', id:string}

--- @param s unidiff.Session
--- @return unidiff.SelectionId?
local function selection_id(s)
  local t = s.selected
  if not t then
    return nil
  end
  local named = ({
    file = function()
      local e = s.entries[t.index]
      return e and e.path
    end,
    commit = function()
      local c = s.commits[t.index]
      return c and c.sha
    end,
    commit_file = function()
      local c = s.scope and s.scope.changes[t.index]
      return c and c.path
    end,
  })[t.kind]()
  return named and { kind = t.kind, id = named } or nil
end

--- The reverse of `selection_id` against the lists as they now are.
--- @param s unidiff.Session
--- @param id unidiff.SelectionId?
--- @return unidiff.ListTarget?
local function target_of_id(s, id)
  if not id then
    return nil
  end
  local haystack, name
  if id.kind == 'file' then
    haystack, name = s.entries, 'path'
  elseif id.kind == 'commit' then
    haystack, name = s.commits, 'sha'
  else
    haystack, name = s.scope and s.scope.changes or {}, 'path'
  end
  for i, it in ipairs(haystack) do
    if it[name] == id.id then
      return { kind = id.kind, index = i }
    end
  end
  return nil
end

--- The nearest row at or above `row` that stands for something.
---
--- Rows standing for nothing used to be rare enough to ignore: the list held
--- paths and, when there were none, one notice. A commit section adds a blank
--- row and a header in the middle of the list, and a cursor left on either of
--- those selects nothing while looking as though it selects a file.
---
--- @param s unidiff.Session
--- @param row integer 1-based
--- @return integer row
local function settle(s, row)
  for r = row, 1, -1 do
    if list.target_at(s.list_buf, r) then
      return r
    end
  end
  return 1
end

--- Draw the list from the session's state and settle the cursor on `target`.
---
--- Failing that — the file was committed away, say — the row is kept and
--- clamped, since the list is usually shorter afterwards, not longer.
---
--- @param s unidiff.Session
--- @param target unidiff.ListTarget? where the cursor should end up
local function redraw_list(s, target)
  list.draw(s.list_buf, {
    root = s.root,
    entries = s.entries,
    commits = s.commits,
    scope = s.scope,
  })
  local row = list.row_of(s.list_buf, target)
  if not row then
    local last = vim.api.nvim_buf_line_count(s.list_buf)
    row = settle(s, math.min(vim.api.nvim_win_get_cursor(s.list_win)[1], last))
  end
  vim.api.nvim_win_set_cursor(s.list_win, { row, 0 })

  -- The row under the cursor may now be a different file, or the same file with
  -- different contents, so the diff is rebuilt either way.
  sync_selection(s, true)
end

--- Re-read the repository and redraw both panes.
---
--- A commit is immutable, so looking into one survives a refresh untouched. What
--- is re-read is everything underneath it, which is what the list goes back to.
---
--- @param s unidiff.Session
function M.refresh(s)
  local entries, err = status.list(s.root)
  if not entries then
    util.git_error(err)
    return
  end
  local id = selection_id(s)
  s.entries = entries
  -- Re-read rather than kept from `open`: the first commit can be made while
  -- the session is open, and it is one process against the several `status.list`
  -- already spends. The log is re-read for the same reason.
  s.has_head = git.has_head(s.root)
  s.commits = read_commits(s)
  redraw_list(s, target_of_id(s, id))
end

--- Look into the commit under the cursor: its files replace the list, and
--- selecting one shows that file's diff by itself.
---
--- The change list is read once, here, and kept: it is what the rows stand for
--- and what each file's versions are then read against.
---
--- @param s unidiff.Session
function M.enter(s)
  local target = s.selected
  local commit = target and target.kind == 'commit' and s.commits[target.index] or nil
  if not commit then
    return
  end
  local changes, err = git.changed_in(commit, s.root)
  if not changes then
    util.git_error({ what = 'git diff ' .. commit.sha, stderr = err or '' })
    return
  end
  s.scope = { commit = commit, changes = changes }
  redraw_list(s, { kind = 'commit_file', index = 1 })
end

--- Go back to the uncommitted changes, with the cursor on the commit that was
--- being looked into.
--- @param s unidiff.Session
function M.leave(s)
  local scope = s.scope
  if not scope then
    return
  end
  s.scope = nil
  redraw_list(s, target_of_id(s, { kind = 'commit', id = scope.commit.sha }))
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
  local target = s.selected
  if not target then
    return
  end
  if target.kind ~= 'file' then
    util.info('only an uncommitted file can be staged')
    return
  end
  local entry = s.entries[target.index]
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
  local target = s.selected
  local entry = target and target.kind == 'file' and s.entries[target.index] or nil
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
    -- On a commit there is somewhere further in to go; anywhere else the row
    -- already names what the diff is showing.
    if s.selected and s.selected.kind == 'commit' then
      M.enter(s)
      return
    end
    vim.api.nvim_set_current_win(s.diff_win)
  end, 'unidiff: look into the commit, or focus the diff')
  map('<BS>', function()
    M.leave(s)
  end, 'unidiff: back out of the commit')
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
      local t = s.selected
      -- A whole commit's diff is every file it touched, in one buffer, so
      -- moving between files there means scrolling within it rather than moving
      -- the list's cursor. Every other view holds one file.
      if t and t.kind == 'commit' then
        keymap.jump(dir, 'files')
        return
      end
      select_nth(s, t and t.kind == 'commit_file' and 'commit_file' or 'file', (t and t.index or 1) + dir)
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
    commits = {},
    generation = 0,
    has_head = git.has_head(root),
  }
  s.commits = read_commits(s)
  vim.api.nvim_win_set_buf(s.list_win, s.list_buf)
  -- An explicit side, rather than `:vsplit`, which follows 'splitright'.
  s.diff_win = vim.api.nvim_open_win(s.diff_buf, false, {
    split = 'right',
    win = s.list_win,
  })

  list.draw(s.list_buf, { root = root, entries = entries, commits = s.commits })
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
