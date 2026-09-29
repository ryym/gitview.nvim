--- One tab page showing a repository's uncommitted changes: the file list on
--- the left, the selected file's diff on the right.
---
--- A session outlives the moment it was opened in. It keeps enough state to be
--- redrawn when the repository changes underneath it — which it does by itself
--- on entering its tab page — and to follow the cursor from one file to the next.
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
--- @field entries unidiff.StatusEntry[] empty until the first read finishes
--- @field files_notice string? shown in place of the files while there are none
---        to show yet: until the first read finishes, or after it failed
--- @field reads integer bumped by every read of the status, so a read can tell
---        whether a later one has made it obsolete
--- @field reading boolean? whether a read of the status is under way
--- @field outdated boolean? whether the session has changed the index since the
---        panes were drawn. Staging from them then would write back the state
---        they show, undoing the change, so it waits for the read to catch up
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
--- @field commits_stale boolean? whether `commits` is a list `git log` no longer
---        agrees with, held open because the cursor is on a commit it dropped
--- @field refreshed_at integer? when the repository was last re-read, in
---        milliseconds, so that automatic refreshes can be throttled
--- @field watcher uv.uv_fs_poll_t? watches the index for writes; nil when the
---        git directory could not be resolved
--- @field index_lines string[]? the selected file's index contents, for staging
---        part of it; nil whenever the pane shows a notice instead of a diff
--- @field details table<string, unidiff.CommitDetail> commits' messages and
---        stats by sha, read once: a commit never changes

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
  local named
  if t.kind == 'file' then
    local e = s.entries[t.index]
    named = e and e.path
  elseif t.kind == 'commit' then
    local c = s.commits[t.index]
    named = c and c.sha
  else
    local c = s.scope and s.scope.changes[t.index]
    named = c and c.path
  end
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

--- The message and stat of a commit, read on first use.
--- @param s unidiff.Session
--- @param commit unidiff.Commit
--- @return unidiff.CommitDetail?
local function commit_detail(s, commit)
  if not s.details[commit.sha] then
    local detail, err = git.commit_detail(commit, s.root)
    if not detail then
      -- the diff under it is still worth showing
      util.git_error(assert(err))
      return nil
    end
    s.details[commit.sha] = detail
  end
  return s.details[commit.sha]
end

--- Draw what the commits pane's cursor compares: one commit against its first
--- parent, or the stretch between it and the mark.
---
--- This is a two-version view: there is no index between the sides and so
--- nothing to mark as staged.
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
  -- A range between two commits has no one message to show.
  if vim.deep_equal(range, git.commit_range(commit)) then
    local detail = commit_detail(s, commit)
    if detail then
      vlib.prepend(view, vlib.commit_header(detail))
    end
  end
  render.draw(s.diff_buf, view)
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
end

--- Draw whatever is selected, or say why there is nothing to draw.
---
--- The index contents are kept, since staging writes the chosen rows into them.
---
--- @param s unidiff.Session
--- @param keep_unchanged boolean? leave the pane as it is when it already shows
---        what the selection names. Only for a caller that knows the contents
---        cannot have changed; see `refresh`.
function M.show_selected(s, keep_unchanged)
  -- The comparison is by what is shown rather than by the target, because a
  -- refresh can move a file to another index while it goes on being the same
  -- file.
  local id = selection_id(s)

  -- A commit and a range are named by sha, so what they compare cannot have
  -- changed and the view already drawn still stands. A file is named by its path
  -- alone: the working tree moves under it, so the name says nothing about the
  -- contents and it has to be built again.
  if keep_unchanged and id and id.kind ~= 'file' and vim.deep_equal(id, s.shown) then
    return
  end
  s.index_lines = nil

  -- Redrawing the same thing keeps the position in it: that is what staging a
  -- hunk does, and being thrown back to the top on every `s` would make working
  -- down a diff impossible. Anything else is new contents in a reused buffer,
  -- where an inherited position means nothing.
  if not vim.deep_equal(id, s.shown) then
    reset_view(s)
  end
  s.shown = id

  local target = s.selected
  if not target then
    render.notice(s.diff_buf, s.files_notice or list.EMPTY_NOTICE)
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
  view.note = note_of(s)
  render.draw(s.diff_buf, view)
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
--- @param keep_unchanged boolean? passed on to `show_selected`
local function sync_selection(s, win, force, keep_unchanged)
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
    M.show_selected(s, keep_unchanged)
    return
  end
  local generation = s.generation
  vim.defer_fn(function()
    if s.generation == generation and vim.api.nvim_buf_is_valid(s.diff_buf) then
      M.show_selected(s, keep_unchanged)
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
  -- The cursor now stands on the row that was asked for, so following it is all
  -- that is left to do.
  sync_selection(s, win)
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
--- @param keep_unchanged boolean? passed on to `show_selected`
local function redraw_list(s, target, keep_unchanged)
  list.draw(s.files_buf, {
    pane = 'files',
    root = s.root,
    entries = s.entries,
    notice = s.files_notice,
  })
  list.draw(s.commits_buf, {
    pane = 'commits',
    root = s.root,
    commits = s.commits,
    mark = s.mark,
    scope = s.scope,
    stale = s.commits_stale,
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
  -- different contents, so the diff is rebuilt either way unless the caller says
  -- it knows better.
  sync_selection(s, win, true, keep_unchanged)
end

--- Re-read the commit list, unless replacing it would pull the selected commit
--- out from under the cursor.
---
--- A commit the log no longer names — rewritten, reset away, or pushed off the
--- end of the list — is still a readable object, so the diff pane goes on
--- showing it. What cannot be done is to put a list without it in front of the
--- cursor: the selection is re-derived from the row the cursor is on, so the
--- commit that row now holds would silently be selected in its place. The old
--- list is kept until the cursor leaves it, and the pane says so in its winbar.
---
--- @param s unidiff.Session
--- @param id unidiff.SelectionId? what is selected, named before the re-read
local function read_log(s, id)
  -- Re-read rather than kept from `open`: the first commit can be made while
  -- the session is open, and it is one process against the several `status.list`
  -- already spends.
  s.has_head = git.has_head(s.root)
  local commits = read_commits(s)
  if id and id.kind == 'commit' then
    local found = false
    for _, c in ipairs(commits) do
      if c.sha == id.id then
        found = true
        break
      end
    end
    if not found then
      s.commits_stale = true
      return
    end
  end
  s.commits = commits
  s.commits_stale = nil
  -- A mark on a commit that has dropped off the end of the list would go on
  -- widening every range while no row showed where it was. It is only ever
  -- cleared along with the list it pointed into.
  if s.mark and not commit_by_sha(s, s.mark) then
    s.mark = nil
  end
end

--- Read the uncommitted changes in the background, then redraw both panes.
---
--- Listing untracked files walks the whole working tree, which takes a second in
--- a large one, so the panes stay usable on what they already show meanwhile.
--- Only the latest read is drawn: one that a later read has overtaken is out of
--- date by the time it finishes, whichever finishes first.
---
--- The log is read here too, synchronously, once the status is in. It is a
--- single cheap process, and reading it along with the status keeps the two
--- panes describing the same moment.
---
--- @param s unidiff.Session
--- @param report boolean whether to tell the user when git fails
--- @param keep_unchanged boolean? passed on to `show_selected`
local function read_status(s, report, keep_unchanged)
  s.reads = s.reads + 1
  local read = s.reads
  s.reading = true
  git.async(function()
    return status.list(s.root)
  end, function(entries, err)
    if s.reads ~= read or M.sessions[s.tab] ~= s then
      return
    end
    s.reading = nil
    if not entries then
      if report then
        util.git_error(err)
      end
      -- A list already on screen is still the best there is, but a notice
      -- promising one that is on its way would be a lie from here on.
      if s.files_notice then
        s.files_notice = list.UNREADABLE_NOTICE
        redraw_list(s, nil, true)
      end
      return
    end
    local id = selection_id(s)
    s.entries = entries
    s.files_notice = nil
    s.outdated = nil
    -- While a range is being looked into, the commits pane shows its files and
    -- the log behind them is off screen, so re-reading it would buy nothing.
    -- Backing out is what reads it again.
    if not s.scope then
      read_log(s, id)
    end
    redraw_list(s, target_of_id(s, id), keep_unchanged)
  end)
end

--- How long an automatic refresh waits after the last one.
---
--- `TabEnter` fires on every move between tab pages, and a refresh is seven
--- subprocesses and a view, so without this a session would re-read the
--- repository on each one, including a glance at another tab page and straight
--- back.
local REFRESH_THROTTLE_MS = 300

--- Re-read the repository and redraw both panes, once the read has finished in
--- the background; see `read_status`.
---
--- A commit is immutable, so looking into one survives a refresh untouched. What
--- is re-read is everything underneath it, which is what the list goes back to.
---
--- @param s unidiff.Session
--- @param opts? {auto?:boolean} `auto` for a refresh nothing asked for. It is
---        throttled, it says nothing when git fails, since the trigger will come
---        again and a message per attempt would be noise, and it leaves the diff
---        pane alone when what it shows cannot have changed.
function M.refresh(s, opts)
  local auto = opts and opts.auto or false
  local now = math.floor(vim.uv.hrtime() / 1000000)
  if auto and s.refreshed_at and now - s.refreshed_at < REFRESH_THROTTLE_MS then
    return
  end
  s.refreshed_at = now
  read_status(s, not auto, auto)
end

--- Follow the list's cursor, replacing a held-back commit list first.
---
--- A list held open for a commit the log dropped is only in the way once the
--- cursor has moved off that commit, which is the moment this is called. What the
--- cursor has moved to is named before the list is replaced and found again
--- afterwards, so the row it lands on is the one it chose rather than the one it
--- happened to be on.
---
--- @param s unidiff.Session
--- @param win integer the pane whose cursor decides the selection
function M.follow_cursor(s, win)
  if s.commits_stale then
    local buf = vim.api.nvim_win_get_buf(win)
    local target = list.target_at(buf, vim.api.nvim_win_get_cursor(win)[1])
    if not list.same_target(target, s.selected) then
      s.selected = target
      read_log(s, nil)
      redraw_list(s, target_of_id(s, selection_id(s)))
      return
    end
  end
  sync_selection(s, win)
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

--- The commit the cursor is on, or nil when it is not on a commit row.
--- @param s unidiff.Session
--- @return unidiff.Commit?
--- @return unidiff.ListTarget?
local function selected_commit(s)
  local target = s.selected
  if not target or target.kind ~= 'commit' then
    return nil, nil
  end
  return s.commits[target.index], target
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
  local commit, target = selected_commit(s)
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
  local commit, target = selected_commit(s)
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
  local id = { kind = 'commit', id = scope.at } --- @type unidiff.SelectionId
  -- The log went unread while the range's files stood in front of it, and it may
  -- have moved on since. Reading it here is also what decides whether the commit
  -- being backed out onto is still in it.
  read_log(s, id)
  redraw_list(s, target_of_id(s, id))
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
  local path = vim.fs.joinpath(s.root, entry.path)
  if vim.fn.filereadable(path) == 0 then
    util.warn(('%s is not in the working tree'):format(entry.path))
    return
  end
  M.close(s)
  vim.cmd.edit(vim.fn.fnameescape(path))
end

--- Refuse to stage from panes the session has made out of date, saying why.
--- @param s unidiff.Session
--- @return boolean refused
local function wait_for_read(s)
  if not s.outdated then
    return false
  end
  util.info('the status is being re-read; try again in a moment, or refresh with R')
  return true
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
  if not target or wait_for_read(s) then
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
  s.outdated = true
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
  if wait_for_read(s) then
    return
  end
  local target = s.selected
  local entry = target and target.kind == 'file' and s.entries[target.index] or nil
  local view = render.view_of(s.diff_buf)
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
  s.outdated = true
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
  local map = util.buf_mapper(s.diff_buf)
  for _, op in ipairs({ 'stage', 'unstage' }) do
    local lhs = op == 'stage' and 's' or 'u'
    for _, mode in ipairs({ 'n', 'x' }) do
      map(lhs, function()
        apply_to_rows(s, op, pressed_rows(mode == 'x'))
      end, ('%s the selected lines'):format(op), { mode })
    end
    map(lhs:upper(), function()
      local view = render.view_of(s.diff_buf)
      local first, last = index.hunk_at(view and view.lines or {}, vim.fn.line('.'))
      if not first then
        util.info('not inside a change')
        return
      end
      apply_to_rows(s, op, first, last)
    end, ('%s this hunk'):format(op))
  end
end

--- The keys both panes of the sidebar share.
--- @param s unidiff.Session
--- @param buf integer
local function set_shared_keymaps(s, buf)
  local map = util.buf_mapper(buf)
  map('R', function()
    M.refresh(s)
  end, 'refresh')
  map('q', function()
    M.close(s)
  end, 'close')
end

--- What the keys do in the files pane.
--- @param s unidiff.Session
local function set_files_keymaps(s)
  local map = util.buf_mapper(s.files_buf)
  map('<CR>', function()
    vim.api.nvim_set_current_win(s.diff_win)
  end, 'focus the diff')
  -- `s` and `u` rather than one key toggling: a file with changes on both sides
  -- has no obvious sense in which it is on or off, and a row here states that
  -- state rather than hiding it, so the direction is given explicitly.
  map('s', function()
    apply_to_selected(s, stage.stage)
  end, 'stage the file under the cursor')
  map('u', function()
    apply_to_selected(s, stage.unstage)
  end, 'unstage the file under the cursor')
  map('o', function()
    M.edit_entry(s)
  end, 'edit the file under the cursor')
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
  local map = util.buf_mapper(s.commits_buf)
  map('<CR>', function()
    -- On a commit there is somewhere further in to go; on one of its files the
    -- row already names what the diff is showing.
    if s.scope then
      vim.api.nvim_set_current_win(s.diff_win)
      return
    end
    M.enter(s)
  end, 'look into the commit or range, or focus the diff')
  map('<BS>', function()
    M.leave(s)
  end, 'back out of the commit')
  map('m', function()
    M.toggle_mark(s)
  end, 'mark this commit as the far end of a range')
  for _, lhs in ipairs({ 's', 'u' }) do
    map(lhs, function()
      util.info('only an uncommitted file can be staged')
    end, 'nothing to stage here')
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
    util.buf_mapper(buf)('gw', function()
      M.toggle_whitespace(s)
    end, 'toggle ignoring whitespace')
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
        keymap.jump_files(dir)
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

--- Whether the shared autocommands have been created.
local hooks_set = false

--- Re-read a session whenever the repository may have moved on behind it.
---
--- `TabEnter` catches whatever happened while another tab page was current, which
--- covers the repository being changed from outside Neovim and then switched back
--- to. It cannot catch a change made while the session's own tab page stays
--- current; that is what `R` is still for.
---
--- `FocusGained` would catch coming back to Neovim without changing tab pages,
--- but it needs the terminal to report focus, which tmux does not do unless
--- `focus-events` is on. Hanging the feature on an event that silently never
--- fires is worse than not having it.
---
--- This is a global event rather than a buffer one, so it is created once for the
--- module instead of once per session, and it does nothing while no session is
--- current. The session's own `tabnew` fires `TabEnter` before the session is
--- registered, which is one such nothing.
local function set_hooks()
  if hooks_set then
    return
  end
  hooks_set = true
  vim.api.nvim_create_autocmd('TabEnter', {
    group = vim.api.nvim_create_augroup('unidiff.ui.session', { clear = true }),
    desc = 'unidiff: re-read the status tab page',
    callback = function()
      local s = M.current()
      if s then
        M.refresh(s, { auto = true })
      end
    end,
  })
end

--- How often the index is looked at to see whether it has been written.
---
--- Slower than the throttle on a refresh, so that a write and a tab page change
--- landing together are still one re-read rather than two.
local INDEX_POLL_MS = 1000

--- Re-read a session whenever another process writes the repository's index.
---
--- This is what `TabEnter` cannot do: catch a change while the session's own tab
--- page is the one being looked at. `git add`, `git commit` and `git checkout`
--- all write `<gitdir>/index`, so watching that one file covers them whatever ran
--- them — another terminal, a tmux pane, a script, another Neovim.
---
--- What it does not cover is a command that moves HEAD without writing the index:
--- `git reset --soft`, an amend of nothing but the message, `git update-ref`.
--- They change what the panes should show and go unnoticed here. Watching `HEAD`
--- as well would not settle it either, since on a branch it is `refs/heads/<name>`
--- that moves and `HEAD` itself holds still. The case is narrow — such a command
--- is nearly always followed by one that does write the index — and `TabEnter`
--- and `R` are both still there, so it is left alone rather than chased.
---
--- It polls rather than subscribing to filesystem events because git does not
--- write the index in place: it writes `index.lock` and renames it over. The
--- inode is replaced on every write, so an `fs_event` watcher would be left
--- holding the file nobody writes to again, while `fs_poll` stats the path by
--- name and follows the replacement.
---
--- @param s unidiff.Session
local function watch_index(s)
  local dir = git.dir(s.root)
  if not dir then
    return
  end
  local watcher = vim.uv.new_fs_poll()
  if not watcher then
    return
  end
  s.watcher = watcher
  watcher:start(
    vim.fs.joinpath(dir, 'index'),
    INDEX_POLL_MS,
    vim.schedule_wrap(function(err)
      if err or M.current() ~= s then
        return
      end
      -- Every other trigger fires at a break in what the user is doing. This one
      -- fires whenever another process happens to write, so it has to find the
      -- break itself: a redraw during a visual selection would take the lines
      -- being staged out from under the command about to stage them. Dropping
      -- the refresh costs nothing, since finishing that command redraws anyway.
      if vim.fn.mode() ~= 'n' then
        return
      end
      M.refresh(s, { auto = true })
    end)
  )
end

--- Give up the index watcher, which outlives the tab page otherwise.
--- @param s unidiff.Session
local function unwatch_index(s)
  if s.watcher then
    s.watcher:stop()
    s.watcher:close()
    s.watcher = nil
  end
end

--- Open a tab page listing everything uncommitted.
--- @return unidiff.Session?
function M.open()
  local root = source.repo_root()
  if not root then
    return
  end
  set_hooks()
  vim.cmd.tabnew()
  local s = { --- @type unidiff.Session
    tab = vim.api.nvim_get_current_tabpage(),
    root = root,
    files_win = vim.api.nvim_get_current_win(),
    files_buf = list.create_buffer(),
    commits_buf = list.create_buffer(),
    diff_buf = render.create_buffer(),
    entries = {},
    files_notice = list.LOADING_NOTICE,
    reads = 0,
    commits = {},
    generation = 0,
    details = {},
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
  -- Each pane is only ever drawn with its own buffer, so `:edit` or `:bnext`
  -- there is refused rather than leaving a pane the session goes on drawing
  -- into blind. A window split off from a pane does not inherit it, which
  -- leaves `:split` as the way to open something else here.
  for _, win in ipairs({ s.files_win, s.commits_win, s.diff_win }) do
    util.configure_window_options(win, { winfixbuf = true })
  end
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
        M.follow_cursor(s, vim.api.nvim_get_current_win())
      end,
    })
  end

  M.sessions[s.tab] = s
  watch_index(s)
  vim.api.nvim_create_autocmd('TabClosed', {
    group = vim.api.nvim_create_augroup('unidiff.ui.session.' .. s.tab, { clear = true }),
    callback = function()
      -- TabClosed does not say which tab went, so this checks its own.
      if not vim.api.nvim_tabpage_is_valid(s.tab) then
        M.sessions[s.tab] = nil
        unwatch_index(s)
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
  -- Once the files are in, the cursor lands on the first of them, unless it has
  -- been moved to the commits in the meantime: the row it is on in the files
  -- pane is the notice's, which stands for nothing and so names no selection.
  read_status(s, true, true)
  return s
end

return M
