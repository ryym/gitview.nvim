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
--- @field files_win integer
--- @field files_buf integer
--- @field commits_win integer
--- @field commits_buf integer
--- @field diff_win integer
--- @field diff_buf integer drawn into repeatedly, never swapped out
--- @field entries unidiff.StatusEntry[]
--- @field commits unidiff.Commit[] the tail of the history, newest first
--- @field ignore_whitespace boolean whether lines differing only in whitespace
---        count as changed; starts from the configuration and is toggled while
---        the session is open
--- @field mark string? sha of the marked commit. While it is set the commits
---        pane compares it with whatever the cursor is on, rather than showing
---        one commit against its parent
--- @field scope unidiff.ListScope? the range being looked into, whose files
---        replace the commits pane while it is set
--- @field selected unidiff.ListTarget? what the diff pane is showing
--- @field shown unidiff.SelectionId? what it is currently showing, so that
---        redrawing the same thing can keep the scroll position
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

--- The diff options a view of this session is built with.
---
--- Ignoring whitespace is session state rather than configuration: it is a way
--- of looking at one thing, turned on and off again while reading, and the
--- configured value is only where it starts.
--- @param s unidiff.Session
--- @return {algorithm:string, linematch:integer, ignore_whitespace:boolean}
local function diff_opts(s)
  local opts = config.diff_opts(config.values)
  opts.ignore_whitespace = s.ignore_whitespace
  return opts
end

--- Everything the winbar should say about a view beyond what it compares.
--- @param s unidiff.Session
--- @param ... string? notes, in order, nils skipped
--- @return string?
local function note_of(s, ...)
  local notes = {}
  for i = 1, select('#', ...) do
    local note = select(i, ...)
    if note then
      notes[#notes + 1] = note
    end
  end
  -- A mode that silently changes which lines count as different would be a trap.
  if s.ignore_whitespace then
    notes[#notes + 1] = '(whitespace ignored)'
  end
  return #notes > 0 and table.concat(notes, '   ') or nil
end

--- Why there was nothing to draw, as far as the user needs to know.
---
--- With whitespace ignored, a file whose only change is whitespace yields no
--- rows, and calling that "no textual change" would be a lie.
--- @param s unidiff.Session
--- @return string
local function no_view_reason(s)
  if s.ignore_whitespace then
    return '(no change outside whitespace)'
  end
  return '(no textual change)'
end

--- Which pane a kind of target lives in. The sidebar holds two lists, and a
--- selection belongs to exactly one of them.
--- @param s unidiff.Session
--- @param kind 'file'|'commit'|'commit_file'
--- @return integer win
--- @return integer buf
local function pane_of(s, kind)
  if kind == 'file' then
    return s.files_win, s.files_buf
  end
  return s.commits_win, s.commits_buf
end

--- Put the diff pane back at the start.
---
--- The pane is one buffer for the life of the session, so a position in it
--- outlives the contents it belonged to. Without this, a shorter diff drawn
--- after a longer one opens at its end rather than its beginning, because the
--- cursor is merely clamped to the new line count.
--- @param s unidiff.Session
local function reset_view(s)
  if vim.api.nvim_win_is_valid(s.diff_win) then
    vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
  end
end

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

--- The commit with this sha, and where it sits in the list.
--- @param s unidiff.Session
--- @param sha string?
--- @return unidiff.Commit?
--- @return integer? index
local function commit_by_sha(s, sha)
  if not sha then
    return nil, nil
  end
  for i, c in ipairs(s.commits) do
    if c.sha == sha then
      return c, i
    end
  end
  return nil, nil
end

--- What the commits pane compares, given the commit under the cursor.
---
--- With no mark set that is the commit against its own first parent. With one
--- set it is the stretch between the two, ordered by their place in the list
--- rather than by date: the list is what the user is reading, and a rebase or a
--- cherry-pick can leave dates out of order.
---
--- @param s unidiff.Session
--- @param commit unidiff.Commit the one under the cursor
--- @param index integer its place in the list
--- @return unidiff.Range
--- @return string label
local function range_of(s, commit, index)
  local marked, at = commit_by_sha(s, s.mark)
  if not marked or at == index then
    return git.commit_range(commit), ('%s %s'):format(commit.sha, commit.subject)
  end
  -- The list is newest first, so the further down it is, the older it is.
  local older, newer = commit, marked
  if at > index then
    older, newer = marked, commit
  end
  return { old = older.sha, new = newer.sha }, ('%s..%s'):format(older.sha, newer.sha)
end

--- What to say in the winbar about a range beyond what it compares.
---
--- `git diff` compares the two trees whatever their history, but across a fork
--- the result also undoes whatever the other side did, which is not what "the
--- changes between these commits" sounds like. Saying so is better than refusing
--- a comparison the user asked for.
---
--- @param s unidiff.Session
--- @param range unidiff.Range
--- @param commit unidiff.Commit the commit under the cursor
--- @return string?
local function range_note(s, range, commit)
  if not range.old then
    return nil
  end
  if range.new ~= commit.sha or range.old ~= git.commit_range(commit).old then
    -- a range of two chosen commits
    if not git.is_ancestor(range.old, range.new, s.root) then
      return '(diverged; not one line of history)'
    end
    return nil
  end
  if #commit.parents > 1 then
    return '(first parent)'
  end
  return nil
end

--- Draw what the commits pane's cursor compares: one commit against its first
--- parent, or the stretch between it and the mark.
---
--- This is a two-version view, the shape `:UnidiffAll` already produces: there
--- is no index between the sides and so nothing to mark as staged.
--- @param s unidiff.Session
--- @param commit unidiff.Commit?
--- @param index integer? its place in the list
local function show_commit(s, commit, index)
  if not commit or not index then
    render.notice(s.diff_buf, list.EMPTY_NOTICE)
    return
  end
  local range, label = range_of(s, commit, index)
  local sources, skipped, err = source.for_range(range, s.root)
  if not sources then
    util.git_error(err)
    render.notice(s.diff_buf, label .. '   (could not be read)')
    return
  end

  local view, unchanged =
    vlib.build(sources, label, config.values.context, diff_opts(s))
  if not view then
    render.notice(s.diff_buf, ('%s   %s'):format(label, no_view_reason(s)))
    return
  end
  -- Its line numbers are the range's, not the working tree's, so jumping to the
  -- source would land on whatever now occupies that line.
  view.historical = true
  view.note = note_of(s, vlib.skipped_note(skipped, #unchanged), range_note(s, range, commit))
  render.draw(s.diff_buf, view)
  vlib.dispose(view)
end

--- Draw one file of the range being looked into.
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

  local src = source.for_range_change(scope.range, change, s.root)
  local view = src and vlib.build({ src }, scope.label, config.values.context, diff_opts(s))
  if not view then
    -- a pure rename or a mode change: a real change with no lines to show
    render.notice(s.diff_buf, ('%s   %s'):format(label, no_view_reason(s)))
    return
  end
  view.historical = true
  view.note = note_of(s)
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

  -- Redrawing the same thing keeps the position in it: that is what staging a
  -- hunk does, and being thrown back to the top on every `s` would make working
  -- down a diff impossible. Anything else is new contents in a reused buffer,
  -- where an inherited position means nothing.
  --
  -- The comparison is by what is shown rather than by the target, because a
  -- refresh can move a file to another index while it goes on being the same
  -- file.
  local id = selection_id(s)
  if not vim.deep_equal(id, s.shown) then
    reset_view(s)
  end
  s.shown = id

  local target = s.selected
  if not target then
    render.notice(s.diff_buf, list.EMPTY_NOTICE)
    return
  end
  if target.kind == 'commit' then
    show_commit(s, s.commits[target.index], target.index)
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
  local view = src and vlib.build({ src }, REV, config.values.context, diff_opts(s))
  if not view then
    -- a pure rename or a mode change: a real change with no lines to show
    render.notice(s.diff_buf, ('%s   %s'):format(status.label(entry), no_view_reason(s)))
    return
  end
  view.mixed = true
  view.note = note_of(s)
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
--- @param win integer the pane whose cursor decides the selection
--- @param force boolean? draw even when the selection has not moved
local function sync_selection(s, win, force)
  local buf = vim.api.nvim_win_get_buf(win)
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local target = list.target_at(buf, row)
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
  local win, buf = pane_of(s, kind)
  local row = list.row_of(buf, target)
  if row then
    vim.api.nvim_win_set_cursor(win, { row, 0 })
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

--- A pane is usually shorter after a redraw, not longer, and a cursor past the
--- end of a buffer is an error the next time anything reads it.
--- @param win integer
local function clamp_cursor(win)
  local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  local row = vim.api.nvim_win_get_cursor(win)[1]
  if row > last then
    vim.api.nvim_win_set_cursor(win, { last, 0 })
  end
end

--- Draw both panes of the sidebar from the session's state, and put the cursor
--- on `target`.
---
--- Failing that — the file was committed away, say — each pane keeps the row it
--- was on, and the selection is taken from whichever pane it was already in.
---
--- @param s unidiff.Session
--- @param target unidiff.ListTarget? where the cursor should end up
local function redraw_list(s, target)
  list.draw(s.files_buf, { pane = 'files', root = s.root, entries = s.entries })
  list.draw(s.commits_buf, {
    pane = 'commits',
    root = s.root,
    commits = s.commits,
    mark = s.mark,
    scope = s.scope,
  })
  clamp_cursor(s.files_win)
  clamp_cursor(s.commits_win)

  local from = target or s.selected
  local win, buf = pane_of(s, from and from.kind or 'file')
  local row = target and list.row_of(buf, target)
  if row then
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end

  -- The row under the cursor may now be a different file, or the same file with
  -- different contents, so the diff is rebuilt either way.
  sync_selection(s, win, true)
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
  -- A mark on a commit that has dropped off the end of the list would go on
  -- widening every range while no row showed where it was.
  if s.mark and not commit_by_sha(s, s.mark) then
    s.mark = nil
  end
  redraw_list(s, target_of_id(s, id))
end

--- Start counting lines that differ only in whitespace as changed again, or stop.
---
--- The view is rebuilt rather than redrawn, because which lines differ is what
--- changed. The position in it is kept: it is the same file being read.
--- @param s unidiff.Session
function M.toggle_whitespace(s)
  s.ignore_whitespace = not s.ignore_whitespace
  s.generation = s.generation + 1
  M.show_selected(s)
end

--- Mark the commit under the cursor, or clear the mark if it is already there.
---
--- One mark rather than two: the far end is marked and the near end is wherever
--- the cursor goes, so a range is read by moving rather than by a second key.
--- The commits pane is short and a range is often long, which is what makes
--- moving the better half to leave free.
---
--- @param s unidiff.Session
function M.toggle_mark(s)
  local target = s.selected
  local commit = target and target.kind == 'commit' and s.commits[target.index] or nil
  if not commit then
    return
  end
  s.mark = s.mark ~= commit.sha and commit.sha or nil
  redraw_list(s, target)
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
  local range, label = range_of(s, commit, target.index)
  local changes, err = git.changed_between(range, s.root)
  if not changes then
    util.git_error({ what = 'git diff ' .. label, stderr = err or '' })
    return
  end
  s.scope = { range = range, label = label, at = commit.sha, changes = changes }
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
  redraw_list(s, target_of_id(s, { kind = 'commit', id = scope.at }))
end

--- @param s unidiff.Session
function M.close(s)
  if not vim.api.nvim_tabpage_is_valid(s.tab) then
    return
  end
  -- `tabclose` refuses when it is the only tab page; there is nothing to go
  -- back to then, so the windows are closed instead. The last one goes through
  -- `:quit`, which is what decides whether Neovim itself should exit.
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(s.tab)
    vim.cmd.tabclose()
  else
    for _, win in ipairs({ s.diff_win, s.commits_win }) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    vim.cmd.quit()
  end
end

--- Open the file under the cursor in place of the session.
--- @param s unidiff.Session
function M.edit_entry(s)
  local row = vim.api.nvim_win_get_cursor(s.files_win)[1]
  local entry = list.entry_at(s.files_buf, row)
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
  -- Ignoring whitespace folds a line that differs only in whitespace into a
  -- context row, whose text is read from the index. Writing the shown rows back
  -- would then leave that line at its index version while the working tree kept
  -- the other, and the view — still ignoring whitespace — would go on showing
  -- nothing unstaged. Whole-file `s` is unaffected: it is `git add`, and reads no
  -- rows.
  if s.ignore_whitespace then
    util.warn('whitespace is being ignored; stage the whole file, or turn it off with gw')
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

--- The keys both panes of the sidebar share.
--- @param s unidiff.Session
--- @param buf integer
local function set_shared_keymaps(s, buf)
  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, desc = desc })
  end
  map('R', function()
    M.refresh(s)
  end, 'unidiff: refresh')
  map('q', function()
    M.close(s)
  end, 'unidiff: close')
end

--- What the keys do in the files pane.
--- @param s unidiff.Session
local function set_files_keymaps(s)
  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = s.files_buf, desc = desc })
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
  map('o', function()
    M.edit_entry(s)
  end, 'unidiff: edit the file under the cursor')
  set_shared_keymaps(s, s.files_buf)
end

--- What the keys do in the commits pane.
---
--- Separating the panes is what lets each one carry only the keys that mean
--- something in it. `s` and `u` are the exception: they are mapped in order to
--- say why they do nothing, since leaving them unmapped would let `s` reach a
--- buffer that cannot be modified and error.
---
--- @param s unidiff.Session
local function set_commits_keymaps(s)
  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = s.commits_buf, desc = desc })
  end
  map('<CR>', function()
    -- On a commit there is somewhere further in to go; on one of its files the
    -- row already names what the diff is showing.
    if s.scope then
      vim.api.nvim_set_current_win(s.diff_win)
      return
    end
    M.enter(s)
  end, 'unidiff: look into the commit or range, or focus the diff')
  map('<BS>', function()
    M.leave(s)
  end, 'unidiff: back out of the commit')
  map('m', function()
    M.toggle_mark(s)
  end, 'unidiff: mark this commit as the far end of a range')
  for _, lhs in ipairs({ 's', 'u' }) do
    map(lhs, function()
      util.info('only an uncommitted file can be staged')
    end, 'unidiff: nothing to stage here')
  end
  set_shared_keymaps(s, s.commits_buf)
end

--- Inside a session a diff is one pane of something larger: `q` gives up the
--- whole session, and moving between files means moving the list's cursor
--- rather than scrolling within one buffer.
--- `gw` is mapped in every buffer of the session, since what it changes is what
--- the diff pane shows wherever the cursor happens to be. It shadows the `gw`
--- format operator, which means nothing in a buffer that cannot be modified.
--- @param s unidiff.Session
local function set_whitespace_keymap(s)
  for _, buf in ipairs({ s.files_buf, s.commits_buf, s.diff_buf }) do
    vim.keymap.set('n', 'gw', function()
      M.toggle_whitespace(s)
    end, { buffer = buf, desc = 'unidiff: toggle ignoring whitespace' })
  end
end

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
      local kind = t and t.kind == 'commit_file' and 'commit_file' or 'file'
      select_nth(s, kind, (t and t.index or 1) + dir)
      vim.api.nvim_set_current_win((pane_of(s, kind)))
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
    files_win = vim.api.nvim_get_current_win(),
    files_buf = list.create_buffer(),
    commits_buf = list.create_buffer(),
    diff_buf = render.create_buffer(),
    entries = entries,
    commits = {},
    generation = 0,
    ignore_whitespace = config.values.ignore_whitespace,
    has_head = git.has_head(root),
  }
  s.commits = read_commits(s)
  vim.api.nvim_win_set_buf(s.files_win, s.files_buf)
  -- Explicit sides, rather than `:vsplit` and `:split`, which follow
  -- 'splitright' and 'splitbelow'.
  s.diff_win = vim.api.nvim_open_win(s.diff_buf, false, {
    split = 'right',
    win = s.files_win,
  })
  s.commits_win = vim.api.nvim_open_win(s.commits_buf, false, {
    split = 'below',
    win = s.files_win,
  })

  list.configure_window(s.files_win, config.values.list_width)
  list.configure_window(s.commits_win, config.values.list_width)
  render.configure_window(s.diff_win, s.diff_buf)
  -- The split is even until told otherwise, and the commits pane is the one
  -- pinned: what the sidebar gains or loses on a resize belongs to the files,
  -- which is the list that grows without bound.
  local total = vim.api.nvim_win_get_height(s.files_win)
    + vim.api.nvim_win_get_height(s.commits_win)
  vim.api.nvim_win_set_height(
    s.commits_win,
    math.max(1, math.floor(total * config.values.commit_ratio))
  )
  vim.wo[s.commits_win].winfixheight = true

  set_files_keymaps(s)
  set_commits_keymaps(s)
  set_diff_keymaps(s)
  set_diff_stage_keymaps(s)
  set_whitespace_keymap(s)

  for _, buf in ipairs({ s.files_buf, s.commits_buf }) do
    vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinEnter' }, {
      buffer = buf,
      callback = function()
        -- `WinEnter` as well as `CursorMoved`: moving between the two panes does
        -- not move either cursor, so nothing else would tell the diff that the
        -- selection is now the other pane's.
        sync_selection(s, vim.api.nvim_get_current_win())
      end,
    })
  end

  M.sessions[s.tab] = s
  vim.api.nvim_create_autocmd('TabClosed', {
    group = vim.api.nvim_create_augroup('unidiff.ui.session.' .. s.tab, { clear = true }),
    callback = function()
      -- TabClosed does not say which tab went, so this checks its own.
      if not vim.api.nvim_tabpage_is_valid(s.tab) then
        M.sessions[s.tab] = nil
        for _, buf in ipairs({ s.files_buf, s.commits_buf, s.diff_buf }) do
          if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
          end
        end
        return true -- delete the autocommand
      end
    end,
  })

  redraw_list(s, { kind = 'file', index = 1 })
  return s
end

return M
