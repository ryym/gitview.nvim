--- One tab page showing a repository's uncommitted changes: the file list on
--- the left, the selected file's diff on the right.
---
--- A session outlives the moment it was opened in. It keeps enough state to be
--- redrawn when the repository changes underneath it — which it does by itself
--- on entering its tab page — and to follow the cursor from one file to the next.
local autosquash = require('gitview.autosquash')
local config = require('gitview.config')
local dlib = require('gitview.diff.lines')
local git = require('gitview.git')
local index = require('gitview.index')
local keymap = require('gitview.diff.keymap')
local keymaps = require('gitview.keymaps')
local list = require('gitview.ui.list')
local perf = require('gitview.perf')
local place = require('gitview.diff.place')
local render = require('gitview.diff.render')
local review = require('gitview.review')
local source = require('gitview.diff.source')
local stage = require('gitview.stage')
local status = require('gitview.status')
local util = require('gitview.util')
local vlib = require('gitview.diff.view')

local M = {}

--- @class gitview.Session
--- @field tab integer tab page handle
--- @field root string repository root, resolved once
--- @field origin integer tab page `gf` opens files in: the one the session was
---        opened from, or the one opened in its place once that is gone
--- @field files_win integer
--- @field files_buf integer
--- @field commits_win integer
--- @field commits_buf integer
--- @field diff_win integer
--- @field diff_buf integer drawn into repeatedly, never swapped out
--- @field uncommitted gitview.StatusEntry[] every uncommitted file; empty until
---        the first read finishes
--- @field entries gitview.StatusEntry[] the files the list shows: those of
---        `uncommitted` with a change in `layer`
--- @field files_notice string? shown in place of the files while there are none
---        to show yet: until the first read finishes, or after it failed
--- @field reads integer bumped by every read of the status, so a read can tell
---        whether a later one has made it obsolete
--- @field reading boolean? whether a read of the status is under way
--- @field outdated boolean? whether the session has changed the index since the
---        panes were drawn. Staging from them then would write back the state
---        they show, undoing the change, so it waits for the read to catch up
--- @field commits gitview.Commit[] the commits of the list the commits pane
---        shows, newest first; see `listing`
--- @field upstream gitview.Upstream? what the branch tracks; nil when nothing
--- @field unpushed table<string, true>? which of `commits` the upstream does not
---        have, by full sha; nil when there is no upstream
--- @field ignore_whitespace boolean whether lines differing only in whitespace
---        count as changed; starts from the configuration and is toggled while
---        the session is open
--- @field layer gitview.Layer which of the uncommitted changes are shown, in the
---        list and in the diff; starts from the configuration and is switched
---        while the session is open
--- @field placing gitview.Placing? where the next draw of the selection puts the
---        diff's cursor, when keeping its row would not keep the line
--- @field mark string? sha of the marked commit, or `list.WORKTREE` for the
---        working-tree row. While it is set the commits pane compares it with
---        whatever the cursor is on, rather than showing one commit against its
---        parent
--- @field scope gitview.ListScope? the range being looked into, whose files
---        replace the commits pane while it is set
--- @field listing 'log'|'review' which list the commits pane shows: the tail of
---        the history, or the commits a review covers. `commits`, `mark`,
---        `scope` and `commits_stale` are that list's
--- @field away gitview.CommitList? the list not shown, kept while a review is on
---        for the commits pane to switch back to
--- @field review gitview.Review? the range being reviewed, whose files replace
---        the uncommitted ones in the files pane while it is set
--- @field selected gitview.ListTarget? what the diff pane is showing
--- @field shown gitview.SelectionId? what it is currently showing, so that
---        redrawing the same thing can keep the scroll position
--- @field shown_key string? `shown` and what it is compared in; see
---        `position_key`
--- @field drawn {key:string, view:gitview.View}? the view last drawn for
---        `shown_key`, while the diff pane still holds it
--- @field restoring boolean? whether the next view drawn is the first one of
---        what is shown, to be put back where it was last left
--- @field positions table<string, gitview.Position> where the diff pane was
---        last left on each thing shown, by `position_key`
--- @field focused gitview.Focused[] the last two things the diff pane showed
---        while focused, the latest first; see `note_focused`
--- @field generation integer bumped by every draw, so one read in the
---        background can tell whether it is still wanted
--- @field pending {generation:integer, span:gitview.PerfSpan}? the view waiting
---        to be read in the background; see `read_pending`
--- @field loading boolean? whether a view is being read in the background
--- @field has_head boolean whether the repository has a commit; re-read on refresh
--- @field commits_stale boolean? whether `commits` is a list `git log` no longer
---        agrees with, held open because the cursor is on a commit it dropped
--- @field refreshed_at integer? when the repository was last re-read, in
---        milliseconds, so that automatic refreshes can be throttled
--- @field watcher uv.uv_fs_poll_t? watches the index for writes; nil when the
---        git directory could not be resolved
--- @field common_dir string? the directory the worktrees share, once resolved
--- @field upstream_watchers uv.uv_fs_poll_t[]? watch where the upstream's ref is
---        kept; nil when there is no upstream
--- @field watched_ref string? the full name of the ref they watch
--- @field config_watcher uv.uv_fs_poll_t? watches the config, where what a
---        branch tracks is set; nil when the shared directory could not be
---        resolved
--- @field index_lines string[]? the selected file's index contents, for staging
---        part of it; nil whenever the pane shows a notice instead of a diff
--- @field details table<string, gitview.CommitDetail> commits' messages and
---        stats by `range_key` of what each is compared in: a commit never
---        changes, but its stat is read again when the diff pane is no longer
---        the width it was laid out for
--- @field auto_merges table<string, gitview.Remerge|false|'failed'> what git
---        merges the parents of a review's merges to on its own, by the merge's
---        sha; false for a merge git cannot merge so, and 'failed' when it
---        failed to. See `read_auto_merge`
--- @field range_reads table<string, gitview.RangeRead> what the ranges between
---        two commits were last read as, by `range_key`, for `read_range`
--- @field range_order string[] the keys of `range_reads`, least recently used
---        first
--- @field empty_tree string? the empty tree's sha, once a range has needed it
--- @field resized boolean? whether the screen was resized while another tab
---        page was current, leaving the sidebar to be laid out on return
--- @field closing boolean? whether a pane has been closed, which ends the
---        session; the panes left are no longer followed
--- @field autosquash {from:gitview.SelectionId}? the autosquash under way, and
---        the commit it started from. Nothing is read from the repository
---        meanwhile; see `M.autosquash`

--- A range under review: its files in the files pane, one by one, and its
--- commits in the commits pane.
---
--- Both ends are fixed when it starts. A review of the working tree alone starts
--- at the commit HEAD was then rather than at HEAD, so that what is committed
--- while it goes on stays in it.
--- @class gitview.Review: gitview.ListReview
--- @field before gitview.SelectionId? what the files pane had the cursor on
---        before, to go back to at the end
--- @field from string? the commit whose history the review's commits leave out;
---        nil to list every commit the newer end has
--- @field on_head boolean whether the review's commits are of HEAD's history

--- The state of one of the commits pane's lists, put away while the other is
--- shown. Switching back brings all of it back.
--- @class gitview.CommitList
--- @field commits gitview.Commit[]
--- @field stale boolean?
--- @field mark string?
--- @field scope gitview.ListScope?
--- @field at gitview.SelectionId? the row the cursor was on

--- @type table<integer, gitview.Session>
M.sessions = {}

--- @return gitview.Session?
function M.current()
  return M.sessions[vim.api.nvim_get_current_tabpage()]
end

--- What the diff pane compares, by layer. Unlike the diff commands there is no
--- choice of revision here: the point of the view is what has not been
--- committed. The staged layer alone compares HEAD with the index, and the
--- unstaged one the index with the working tree.
--- @type table<gitview.Layer, string>
local REVS = {
  both = 'HEAD, staged + unstaged',
  staged = 'HEAD, staged',
  unstaged = 'index, unstaged',
}

--- @param s gitview.Session
--- @return string
local function rev_of(s)
  return REVS[s.layer]
end

--- The order `gs` goes through the layers in.
--- @type table<gitview.Layer, gitview.Layer>
local NEXT_LAYER = { both = 'staged', staged = 'unstaged', unstaged = 'both' }

--- The files with a change in `layer`.
---
--- An untracked file is unstaged only, as it is everywhere else. So is an
--- unmerged one: its index has no version a commit would take, and resolving it
--- is deciding what to stage.
--- @param entries gitview.StatusEntry[]
--- @param layer gitview.Layer
--- @return gitview.StatusEntry[]
local function in_layer(entries, layer)
  if layer == 'both' then
    return entries
  end
  local has = layer == 'staged' and status.has_staged or status.has_unstaged
  return vim.tbl_filter(has, entries)
end

--- Where to put the diff's cursor once the selection is drawn again, and how to
--- find it there; see gitview.diff.place.
--- @class gitview.Placing
--- @field id gitview.SelectionId what was selected when it was asked for. A draw
---        of anything else drops it.
--- @field anchor gitview.Anchor
--- @field find fun(view: gitview.View, a: gitview.Anchor): integer?

--- What a row names, in terms that survive a redraw. `review` marks a file of
--- the review in the files pane, and `in_review_list` a row of the review's list
--- in the commits pane, so that the same thing in two lists is told apart.
--- @alias gitview.SelectionId {kind:'file'|'commit'|'worktree'|'commit_file'|'dir'|'commit_dir', id:string, review:true?, in_review_list:true?}

--- Whether a row is in the commits pane rather than the files pane.
--- @param t gitview.ListTarget|gitview.SelectionId
--- @return boolean
local function in_commits_pane(t)
  return not t.review and t.kind ~= 'file' and t.kind ~= 'dir'
end

--- Whether a row was named in the commits pane's list that is not shown now.
--- @param s gitview.Session
--- @param id gitview.SelectionId
--- @return boolean
local function in_list_away(s, id)
  return in_commits_pane(id) and (id.in_review_list or false) ~= (s.listing == 'review')
end

--- The range a file or directory of a range belongs to: the one under review
--- or the one looked into, which may be the same range in two lists.
--- @param s gitview.Session
--- @param t gitview.ListTarget|gitview.SelectionId a `commit_file` or `commit_dir`
--- @return gitview.ListScope?
local function scope_of(s, t)
  if t.review then
    return s.review and s.review.scope
  end
  return s.scope
end

--- What a view of a range's files says about the range beyond what it compares.
--- A review says what it found out when it started, as its winbar does.
--- @param s gitview.Session
--- @param t gitview.ListTarget a `commit_file` or `commit_dir`
--- @return string?
local function scope_note(s, t)
  return t.review and s.review and s.review.note or nil
end

--- What a row names, in terms that survive a redraw; see `target_of_id`.
--- @param s gitview.Session
--- @param t gitview.ListTarget?
--- @return gitview.SelectionId?
local function id_of(s, t)
  if not t then
    return nil
  end
  local named
  if t.kind == 'dir' or t.kind == 'commit_dir' then
    named = t.path
  elseif t.kind == 'file' then
    local e = s.entries[t.index]
    named = e and e.path
  elseif t.kind == 'commit' then
    local c = s.commits[t.index]
    named = c and c.sha
  elseif t.kind == 'worktree' then
    named = list.WORKTREE
  else
    local scope = scope_of(s, t)
    local c = scope and scope.changes[t.index]
    named = c and c.path
  end
  if not named then
    return nil
  end
  local listed = in_commits_pane(t) and s.listing == 'review' or nil
  return { kind = t.kind, id = named, review = t.review, in_review_list = listed }
end

--- @param s gitview.Session
--- @return gitview.SelectionId?
local function selection_id(s)
  return id_of(s, s.selected)
end

--- The diff options a view of this session is built with.
---
--- Ignoring whitespace is session state rather than configuration: it is a way
--- of looking at one thing, turned on and off again while reading, and the
--- configured value is only where it starts. So is the layer, which only has a
--- say in a mixed view: a range ending at the working tree compares two
--- versions, with no index between them.
--- @param s gitview.Session
--- @return {algorithm:string, linematch:integer, ignore_whitespace:boolean, layer:gitview.Layer}
local function diff_opts(s)
  local opts = config.diff_opts(config.values)
  opts.ignore_whitespace = s.ignore_whitespace
  opts.layer = s.layer
  return opts
end

--- Everything the winbar should say about a view beyond what it compares.
--- @param s gitview.Session
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
  -- It is named by `git diff`'s own flag for it, which says the same thing in
  -- the fewest cells.
  if s.ignore_whitespace then
    notes[#notes + 1] = '-w'
  end
  return #notes > 0 and table.concat(notes, '   ') or nil
end

--- Why there was nothing to draw, as far as the user needs to know.
---
--- With whitespace ignored, a file whose only change is whitespace yields no
--- rows, and calling that "no textual change" would be a lie.
--- @param s gitview.Session
--- @return string
local function no_view_reason(s)
  if s.ignore_whitespace then
    return '(no change outside whitespace)'
  end
  return '(no textual change)'
end

--- What to call a commit that changed no file at all. Whitespace has no say in
--- it, and "no textual change" would suggest files whose change is elsewhere.
local NO_CHANGE = '(no change)'

--- Which pane a target lives in. The sidebar holds two lists, and a selection
--- belongs to exactly one of them.
--- @param s gitview.Session
--- @param target gitview.ListTarget|gitview.SelectionId
--- @return integer win
--- @return integer buf
local function pane_of(s, target)
  if not in_commits_pane(target) then
    return s.files_win, s.files_buf
  end
  return s.commits_win, s.commits_buf
end

--- Where the diff pane was left on something it showed.
--- @class gitview.Position
--- @field view vim.fn.winsaveview.ret the window's view: cursor and scroll
--- @field anchor gitview.Anchor? what the cursor was on, to find it again in a
---        view that has changed since
--- @field text string the text of the line the cursor was on

--- What a position in the diff pane is kept under: what is selected, and what it
--- is compared in. A commit shows another range once a commit is marked, and a
--- file of a range is only that file in that range, and in the list it is in.
--- @param s gitview.Session
--- @param id gitview.SelectionId
--- @return string
local function position_key(s, id)
  local within = ''
  if id.kind == 'commit' or id.kind == 'worktree' then
    within = s.mark or ''
  elseif id.kind == 'commit_file' or id.kind == 'commit_dir' then
    local scope = scope_of(s, id)
    within = scope and (scope.range.old or '') .. '..' .. (scope.range.new or '') or ''
  end
  return table.concat({ id.kind, id.id, within, id.review and 'review' or '', id.in_review_list and 'list' or '' }, '\0')
end

--- Keep where the diff pane is on what it has drawn, for when that is shown
--- again. Nothing is kept while the pane holds anything else, such as a notice
--- or a placeholder.
--- @param s gitview.Session
local function save_position(s)
  local d = s.drawn
  if not d or render.view_of(s.diff_buf) ~= d.view or not vim.api.nvim_win_is_valid(s.diff_win) then
    return
  end
  local saved = vim.api.nvim_win_call(s.diff_win, vim.fn.winsaveview)
  local line = d.view.lines[saved.lnum]
  s.positions[d.key] = {
    view = saved,
    anchor = place.anchor(d.view, saved.lnum),
    text = line and line.text or '',
  }
end

--- Put the diff pane back where it was last left on what `view` shows.
---
--- A commit never changes, but whatever reads the working tree may have, and so
--- may the layer or whitespace it is shown with. The line the cursor was on is
--- found again, or the one nearest it, and the cursor kept as far down the
--- window as it was. A row that is no line of a file, such as a commit's
--- message, is taken as it was.
--- @param s gitview.Session
--- @param view gitview.View
local function restore_position(s, view)
  local p = s.drawn and s.positions[s.drawn.key]
  if not p then
    return
  end
  local saved = p.view
  local row = p.anchor and place.revisit(view, p.anchor, p.text) or saved.lnum
  row = math.min(row, #view.lines)
  if row == saved.lnum then
    vim.api.nvim_win_call(s.diff_win, function()
      vim.fn.winrestview(saved)
    end)
    return
  end
  vim.api.nvim_win_call(s.diff_win, function()
    vim.fn.winrestview({
      lnum = row,
      col = 0,
      topline = math.max(1, row - (saved.lnum - saved.topline)),
    })
  end)
end

--- What marks a file under review as checked off, and as changed since, in
--- the diff as in the list.
local CHECK_MARKS = {
  checked = { '✓', 'GitviewReviewedMark' },
  changed = { '!', 'GitviewReviewChanged' },
}

--- The paths of the files a review lists.
--- @param r gitview.Review
--- @return string[]
local function review_paths(r)
  return vim.tbl_map(function(c)
    return c.path
  end, r.scope.changes)
end

--- The files of a view, by repository path.
--- @param s gitview.Session
--- @param view gitview.View
--- @return string[]
local function view_paths(s, view)
  return vim.tbl_map(function(f)
    return vim.fs.relpath(s.root, f.path) or f.path
  end, view.files)
end

--- Mark the headers of the files checked off, when the diff pane shows files
--- under review. A view of the same files looked into is left unmarked: it is
--- not the review's, though it shows the same range.
--- @param s gitview.Session
local function paint_checks(s)
  local r, t = s.review, s.selected
  -- Mark only a view drawn for what is selected: while a directory waits to be
  -- read, the pane still holds the view of whatever was selected before.
  local view = render.view_of(s.diff_buf)
  if not (r and t and t.review and view and s.drawn and s.drawn.view == view) then
    return
  end
  local marks = {}
  for i, path in ipairs(view_paths(s, view)) do
    local state = review.state(r.checks, path)
    marks[i] = state and CHECK_MARKS[state] or nil
  end
  render.paint_marks(s.diff_buf, marks)
end

local redraw_checks

--- What a file under review is read as, for a check to record or to compare
--- with: the lines a view was built from when there is one, since what was
--- read is what was on screen, and otherwise the file as it is now. Nil in a
--- range between commits, whose files cannot change.
--- @param s gitview.Session
--- @param r gitview.Review
--- @param path string
--- @param lines string[]? the new side a view was built from
--- @return {hash:string, binary:boolean?}?
local function read_as(s, r, path, lines)
  if r.scope.range.new then
    return nil
  end
  local change
  for _, c in ipairs(r.scope.changes) do
    if c.path == path then
      change = c
      break
    end
  end
  -- A deleted file's view has an empty new side, which a file emptied would
  -- have too.
  if change and change.status == 'D' then
    return { hash = review.DELETED }
  end
  if lines then
    return { hash = review.hash_lines(lines) }
  end
  local binary = change and change.binary or nil
  return { hash = review.hash_file(vim.fs.joinpath(s.root, path), binary), binary = binary }
end

--- Note what the files of a view under review are, from what the view is about
--- to be built of. A file ending at the working tree is read from it whenever
--- its view is, which can be before any refresh notices it has changed.
--- @param s gitview.Session
--- @param target gitview.ListTarget
--- @param sources gitview.Source[]
--- @return boolean moved whether any check changed state
local function see_sources(s, target, sources)
  local r = s.review
  if not (r and target.review) or r.scope.range.new then
    return false
  end
  local moved = false
  for _, src in ipairs(sources) do
    local path = vim.fs.relpath(s.root, src.path) or src.path
    local now = read_as(s, r, path, src.new_lines)
    if now and review.see(r.checks, path, now.hash) then
      moved = true
    end
  end
  return moved
end

--- Draw a view of what is selected. The first one drawn of it puts the cursor
--- back where it was last left on it.
--- @param s gitview.Session
--- @param view gitview.View
local function draw_view(s, view)
  render.draw(s.diff_buf, view)
  s.drawn = s.shown_key and { key = s.shown_key, view = view } or nil
  paint_checks(s)
  local restoring = s.restoring
  s.restoring = nil
  if restoring and vim.api.nvim_win_is_valid(s.diff_win) then
    restore_position(s, view)
  end
end

--- Put the diff pane back at the start.
---
--- The pane is one buffer for the life of the session, so a position in it
--- outlives the contents it belonged to. Without this, a shorter diff drawn
--- after a longer one opens at its end rather than its beginning, because the
--- cursor is merely clamped to the new line count.
--- @param s gitview.Session
local function reset_view(s)
  if vim.api.nvim_win_is_valid(s.diff_win) then
    vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
  end
end

--- Draw a view of what is uncommitted, and put the cursor where `s.placing`
--- asks, if it asked for this view. A row it cannot find is left as it was.
--- @param s gitview.Session
--- @param view gitview.View
local function draw_placed(s, view)
  draw_view(s, view)
  local p = s.placing
  s.placing = nil
  if not p or not vim.deep_equal(p.id, s.shown) or not vim.api.nvim_win_is_valid(s.diff_win) then
    return
  end
  local row = p.find(view, p.anchor)
  if row then
    vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  end
end

--- Ask the next draw of the selection to find the line under the diff's cursor
--- with `find`, rather than keeping its row. Nothing is asked when the diff is
--- not on a line of what is uncommitted.
--- @param s gitview.Session
--- @param find fun(view: gitview.View, a: gitview.Anchor): integer?
--- @param row integer? the row whose line to find; the cursor's by default
local function place_next(s, find, row)
  local view = render.view_of(s.diff_buf)
  if not view or not view.mixed or not vim.api.nvim_win_is_valid(s.diff_win) then
    return
  end
  local anchor = place.anchor(view, row or vim.api.nvim_win_get_cursor(s.diff_win)[1])
  if anchor and s.shown then
    s.placing = { id = s.shown, anchor = anchor, find = find }
  end
end

--- The commits of the list the commits pane shows, or nothing when there is no
--- HEAD to read one from.
---
--- The review's list ends at HEAD as it is now when the review ends at the
--- working tree, so that what is committed during the review is in it.
---
--- `git log` fails outright in a repository with no commit rather than printing
--- an empty log, so the question has to be asked before the command is run.
--- @param s gitview.Session
--- @return gitview.Commit[]
local function read_commits(s)
  if not s.has_head then
    return {}
  end
  local span
  if s.listing == 'review' then
    local r = assert(s.review)
    span = { from = r.from, to = r.scope.range.new }
  end
  local commits, err = git.log(config.values.commit_count, s.root, span)
  if not commits then
    util.git_error({ what = 'git log', stderr = err or '' })
    return {}
  end
  return commits
end

--- What the branch tracks and which commits it does not have yet, or nothing
--- when it tracks nothing.
--- @param s gitview.Session
--- @return gitview.Upstream? upstream
--- @return table<string, true>? unpushed
local function read_upstream(s)
  if not s.has_head then
    return nil, nil
  end
  local upstream = git.upstream(s.root)
  if not upstream then
    return nil, nil
  end
  return upstream, git.unpushed(config.values.commit_count, upstream.sha, s.root)
end

--- How often the upstream's ref is looked at to see whether it has moved.
local UPSTREAM_POLL_MS = 1000

--- Give up watching the upstream's ref.
--- @param s gitview.Session
local function unwatch_upstream(s)
  for _, w in ipairs(s.upstream_watchers or {}) do
    w:stop()
    w:close()
  end
  s.upstream_watchers = nil
  s.watched_ref = nil
end

local on_upstream_poll

--- Repaint which commits are pushed whenever the upstream's ref moves, which a
--- fetch or a push does without writing the index.
---
--- Polled for the same reason as the index: git writes a ref to a lock file and
--- renames it over. A ref is kept in one of two places, and both are watched:
--- its own file, or `packed-refs`, where `git pack-refs` and `git gc` move it.
--- Both are under the directory the worktrees share rather than a worktree's
--- own. Nothing is watched in a repository whose refs are a reftable, which no
--- file stands for; `R` is left for that.
---
--- Only the upstream is read again, not the status or the diff: an editor that
--- fetches by itself in the background would otherwise re-read everything every
--- few minutes for nothing. Painting rather than drawing leaves the buffer, and
--- so a Visual selection in it, alone.
---
--- The ref to watch changes with the branch, and a branch is switched by a
--- command that writes the index, so every read of the upstream comes back here
--- to check the watchers are still on the right ref.
--- @param s gitview.Session
local function watch_upstream(s)
  local ref = s.upstream and s.upstream.ref
  if ref == s.watched_ref then
    return
  end
  unwatch_upstream(s)
  if not ref then
    return
  end
  s.common_dir = s.common_dir or git.common_dir(s.root)
  if not s.common_dir then
    return
  end
  local watchers = {}
  for _, path in ipairs({ ref, 'packed-refs' }) do
    local w = vim.uv.new_fs_poll()
    if w then
      -- A file that is not there is reported as an error, and then as a change
      -- once it appears; either is a reason to look again. A ref only in
      -- `packed-refs` has no file of its own until it next moves.
      w:start(
        vim.fs.joinpath(s.common_dir, path),
        UPSTREAM_POLL_MS,
        vim.schedule_wrap(function()
          on_upstream_poll(s)
        end)
      )
      watchers[#watchers + 1] = w
    end
  end
  s.upstream_watchers = watchers
  s.watched_ref = ref
end

--- Paint which commits the upstream has, unless the list shown is of a review
--- off HEAD's history: what is unpushed is known of HEAD's commits alone, and
--- any other would be painted as pushed.
--- @param s gitview.Session
local function paint_upstream(s)
  local off_head = s.listing == 'review' and not assert(s.review).on_head
  list.paint_upstream(s.commits_buf, not off_head and s.upstream or nil, s.unpushed)
end

--- Read what the branch tracks again, and follow it with the watchers.
--- Does nothing while an autosquash runs; the read when it ends covers what is
--- skipped.
--- @param s gitview.Session
local function reread_upstream(s)
  if s.autosquash then
    return
  end
  s.upstream, s.unpushed = read_upstream(s)
  watch_upstream(s)
end

--- Read the upstream again and repaint, once a poll says it may have moved.
--- @param s gitview.Session
function on_upstream_poll(s)
  -- A list held open for history the log dropped is not the one HEAD has, so
  -- what is pushed would be told of the wrong commits.
  if M.current() ~= s or s.commits_stale then
    return
  end
  reread_upstream(s)
  paint_upstream(s)
end

--- Read the upstream again whenever the config is written, which is where what
--- a branch tracks is set: `git push -u` sets it on a branch's first push, and
--- `git branch -u` and `--unset-upstream` change it, none of them writing the
--- index. Watched whether or not there is an upstream yet, since the commonest
--- of them is the one that sets the first.
---
--- The config is written for much else, each time costing a read of the
--- upstream and nothing more.
--- @param s gitview.Session
local function watch_config(s)
  s.common_dir = s.common_dir or git.common_dir(s.root)
  if not s.common_dir then
    return
  end
  local watcher = vim.uv.new_fs_poll()
  if not watcher then
    return
  end
  s.config_watcher = watcher
  watcher:start(
    vim.fs.joinpath(s.common_dir, 'config'),
    UPSTREAM_POLL_MS,
    vim.schedule_wrap(function(err)
      if not err then
        on_upstream_poll(s)
      end
    end)
  )
end

--- Give up watching the config.
--- @param s gitview.Session
local function unwatch_config(s)
  if s.config_watcher then
    s.config_watcher:stop()
    s.config_watcher:close()
    s.config_watcher = nil
  end
end

--- The commit with this sha, and where it sits in the list.
--- @param s gitview.Session
--- @param sha string?
--- @return gitview.Commit?
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

--- Whether the commits pane has a row for the working tree above the commits.
---
--- Even with nothing uncommitted. A clean working tree compares nothing HEAD's
--- own row does not, but the row is still an end a range can be marked at, and
--- such a range follows whatever is edited afterwards. Not before the status is
--- in, though, since until then the row could not say what it stands for, nor
--- without a commit for it to be compared with. Nor in the list of a review
--- that ends at a commit, which the working tree is no part of.
--- @param s gitview.Session
--- @return boolean
local function has_worktree_row(s)
  if s.listing == 'review' and assert(s.review).scope.range.new then
    return false
  end
  return s.has_head and not s.files_notice
end

--- The files git is not tracking, as the last read of the status found them.
---
--- A range ending at the working tree compares them too, and listing them again
--- for every view would walk the whole working tree each time.
--- @param s gitview.Session
--- @return string[]
local function untracked_paths(s)
  local paths = {}
  for _, e in ipairs(s.uncommitted) do
    if status.is_untracked(e) then
      paths[#paths + 1] = e.path
    end
  end
  return paths
end

--- Where the row a mark names sits among the ends a range can have: 0 for the
--- working tree, which is newer than any commit, then the commits newest first.
--- @param s gitview.Session
--- @param mark string? a sha, or `list.WORKTREE`
--- @return integer?
local function place_of(s, mark)
  if mark == list.WORKTREE then
    return has_worktree_row(s) and 0 or nil
  end
  local _, at = commit_by_sha(s, mark)
  return at
end

--- The two ends of a range chosen with the mark, or nothing when the cursor
--- shows one thing on its own: there is no mark, or the cursor is on it.
---
--- They are ordered by their place in the list rather than by date: the list is
--- what the user is reading, and a rebase or a cherry-pick can leave dates out
--- of order. The list is newest first, so the further down it is, the older it
--- is. The older end is always a commit, since the working tree is the newest of
--- all.
---
--- @param s gitview.Session
--- @param target gitview.ListTarget a commit or the working tree
--- @return gitview.Commit? older
--- @return gitview.Commit? newer nil for the working tree
local function ends_of(s, target)
  local here = target.kind == 'worktree' and 0 or target.index
  local at = place_of(s, s.mark)
  if not at or at == here then
    return nil, nil
  end
  return s.commits[math.max(here, at)], s.commits[math.min(here, at)]
end

--- Read what git merges a merge's parents to on its own, before anyone resolves
--- a conflict, once per merge: see `whole_range`.
--- @param s gitview.Session
--- @param commit gitview.Commit a merge
local function read_auto_merge(s, commit)
  if s.auto_merges[commit.sha] ~= nil then
    return
  end
  -- `merge-tree` takes two sides, so a merge of more cannot be merged so.
  if #commit.parents > 2 or not git.can_remerge(s.root) then
    s.auto_merges[commit.sha] = false
    return
  end
  local r, err = git.remerge(commit.parents[1], commit.parents[2], s.root)
  if not r then
    util.git_error(assert(err))
  end
  s.auto_merges[commit.sha] = r or 'failed'
end

--- What a commit on its own is compared with, and what to say of it.
---
--- A commit is compared with its parent, and a merge in the log with its first
--- parent, as `git show` does: nothing there says which side it is to be read
--- against. In the review's list a merge is compared with its automatic merge,
--- what git merges its parents to before anyone resolves a conflict, so that
--- what merged cleanly is left out and what was done by hand is shown. One git
--- cannot merge so is compared with its first parent, and says so as in the
--- log.
---
--- The automatic merge is read with git, which only a caller that may wait on
--- git asks for. Without it a merge whose automatic merge is not read yet has
--- no range to give.
--- @param s gitview.Session
--- @param commit gitview.Commit
--- @param may_read boolean? whether git may be run
--- @return gitview.Range? range
--- @return string? note
local function whole_range(s, commit, may_read)
  local first = git.commit_range(commit)
  if #commit.parents < 2 then
    return first
  end
  if s.listing ~= 'review' then
    return first, 'first parent'
  end
  if may_read then
    read_auto_merge(s, commit)
  end
  local r = s.auto_merges[commit.sha]
  if r == nil then
    return nil
  end
  if not r then
    return first, 'first parent'
  end
  if r == 'failed' then
    return first, 'first parent (remerge failed)'
  end
  return { old = r.tree, new = commit.sha }
end

--- What the commits pane compares, given the row under the cursor.
---
--- With no mark set that is the commit against its own first parent, or
--- everything uncommitted on the working-tree row. With one set it is every row
--- from the mark to the cursor, both included, as a selection reads: the range
--- starts at the older end's first parent, the parent a commit on its own is
--- compared with. The cursor on the mark is then that commit on its own, as it
--- would be with no mark at all.
---
--- @param s gitview.Session
--- @param target gitview.ListTarget a commit or the working tree
--- @param may_read boolean? whether git may be run; see `whole_range`
--- @return gitview.Range? range nil for the working tree on its own, which is
---         not a range but the uncommitted changes as the files pane has them,
---         and, unless `may_read`, for a merge `whole_range` has none for yet
--- @return string label
local function range_of(s, target, may_read)
  local older, newer = ends_of(s, target)
  if not older then
    if target.kind == 'worktree' then
      return nil, rev_of(s)
    end
    local commit = s.commits[target.index]
    return (whole_range(s, commit, may_read)), ('%s %s'):format(commit.sha, commit.subject)
  end
  local old = older.parents[1]
  if not old then
    -- A root commit has no parent to start from, so the range starts from
    -- nothing. That cannot be left unnamed as it is for a root commit on its
    -- own: `diff-tree --root` compares one commit with its parent, not two ends.
    s.empty_tree = s.empty_tree or git.empty_tree(s.root)
    old = s.empty_tree
  end
  local new = newer and newer.sha or nil
  -- `^..` rather than `..`: git's `a..b` leaves `a` out, and this has it in.
  return { old = old, new = new }, ('%s^..%s'):format(older.sha, new or 'working tree')
end

--- The commit a range chosen at `target` starts from the parent of: the older
--- end, or the commit on its own. Nil for the working tree on its own.
--- @param s gitview.Session
--- @param target gitview.ListTarget a commit or the working tree
--- @return string?
local function first_of(s, target)
  local older = ends_of(s, target)
  if older then
    return older.sha
  end
  local commit = target.kind == 'commit' and s.commits[target.index]
  return commit and commit.sha or nil
end

--- What to say in the winbar about a range beyond what it compares.
---
--- `git diff` compares the two trees whatever their history, but across a fork
--- the result also undoes whatever the other side did, which is not what "the
--- changes between these commits" sounds like. Saying so is better than refusing
--- a comparison the user asked for. The working tree stands on HEAD, so a range
--- ending there is asked about HEAD.
---
--- @param s gitview.Session
--- @param range gitview.Range
--- @param target gitview.ListTarget the row under the cursor
--- @param read gitview.RangeRead the range's contents, which keep the answer
--- @return string?
local function range_note(s, range, target, read)
  local older = ends_of(s, target)
  if not older then
    local commit = target.kind == 'commit' and s.commits[target.index] or nil
    return commit and select(2, whole_range(s, commit)) or nil
  end
  -- The range starts at the older end's parent, so it holds the older end
  -- itself only when that is an ancestor of the newer one. Asked of the end
  -- rather than of where the range starts, and kept by it: two ends sharing a
  -- parent start the same range, yet only one of them may lie on the line.
  if read.diverged[older.sha] == nil then
    read.diverged[older.sha] = not git.is_ancestor(older.sha, range.new or 'HEAD', s.root)
  end
  if read.diverged[older.sha] then
    return 'diverged'
  end
  -- Say so of a merge in a range of the review's list, since the diff then holds
  -- what it brought in from commits the list may leave out, those of the base.
  if s.listing == 'review' then
    local here = target.kind == 'worktree' and 0 or target.index
    local at = assert(place_of(s, s.mark))
    for i = math.max(1, math.min(here, at)), math.max(here, at) do
      if #s.commits[i].parents > 1 then
        return 'merge in range'
      end
    end
  end
  return nil
end

--- What a view of a range is built from, as read from git.
--- @class gitview.RangeRead
--- @field sources gitview.Source[]
--- @field skipped gitview.Skipped
--- @field diverged table<string, boolean> whether the ends are on separate lines
---        of history, by the sha of the older end; filled in as `range_note` asks

--- How many ranges a session keeps the contents of. Each holds both versions of
--- every file it changed, so the cache is bounded by count; a few dozen
--- ordinary commits come to a few megabytes.
local RANGE_READS_KEPT = 30

--- The name a range's contents are kept under, or nil for a range ending at
--- the working tree, which can change under the same name.
--- @param range gitview.Range
--- @return string?
local function range_key(range)
  if range.new then
    return (range.old or '') .. '..' .. range.new
  end
  return nil
end

--- What a view leaves out, with the conflicts of `remerge` that the files read
--- show nothing of.
--- @param s gitview.Session
--- @param sources gitview.Source[]
--- @param skipped gitview.Skipped
--- @param remerge gitview.Remerge
--- @return gitview.Skipped
local function with_conflicts_left(s, sources, skipped, remerge)
  local read = {}
  for _, src in ipairs(sources) do
    read[vim.fs.relpath(s.root, src.path) or src.path] = true
  end
  for _, path in ipairs(skipped.binary) do
    read[path] = true
  end
  local conflicts = {}
  for path, kind in pairs(remerge.conflicts) do
    if not read[path] then
      conflicts[#conflicts + 1] = { path = path, kind = kind }
    end
  end
  table.sort(conflicts, function(a, b)
    return a.path < b.path
  end)
  return { binary = skipped.binary, conflicts = conflicts }
end

--- The contents of a range, read from git the first time and kept after that:
--- two commits never change, so neither does what lies between them.
--- @param s gitview.Session
--- @param range gitview.Range
--- @return gitview.RangeRead?
--- @return gitview.GitError? err
local function read_range(s, range)
  local key = range_key(range)
  local kept = key and s.range_reads[key]
  if kept then
    -- most recently used last, so that the first is the one to drop
    for i, k in ipairs(s.range_order) do
      if k == key then
        table.remove(s.range_order, i)
        break
      end
    end
    table.insert(s.range_order, key)
    return kept
  end

  local sources, skipped, err =
    perf.measure('source', source.for_range, range, s.root, untracked_paths(s))
  if not sources then
    return nil, err
  end
  -- A merge compared with its automatic merge lists the conflicts it left as git
  -- left them. They have no diff, and listing them is what shows a side was
  -- dropped: a file deleted on one side and kept by a modify/delete conflict
  -- reads as nothing having happened to it.
  local r = range.new and s.auto_merges[range.new]
  if type(r) == 'table' and r.tree == range.old then
    skipped = with_conflicts_left(s, sources, skipped, r)
  end
  local read = { sources = sources, skipped = skipped, diverged = {} } --- @type gitview.RangeRead
  if key then
    s.range_reads[key] = read
    table.insert(s.range_order, key)
    if #s.range_order > RANGE_READS_KEPT then
      s.range_reads[table.remove(s.range_order, 1)] = nil
    end
  end
  return read
end

--- The columns a commit's stat may take: the diff pane's text area, so that
--- git shortens a long path only when the pane cannot show it whole.
--- @param s gitview.Session
--- @return integer
local function stat_width(s)
  local info = vim.api.nvim_win_is_valid(s.diff_win) and vim.fn.getwininfo(s.diff_win)[1]
  return info and info.width - info.textoff or 80
end

--- The message and stat of a commit as read before, unless the pane has been
--- resized since and the stat laid out for another width.
---
--- Only the next draw notices a resize: a header already shown keeps the
--- width it was read for until its commit is drawn again.
--- @param s gitview.Session
--- @param range gitview.Range what the commit is compared in
--- @return gitview.CommitDetail?
local function kept_detail(s, range)
  local detail = s.details[assert(range_key(range))]
  return detail and detail.stat_width == stat_width(s) and detail or nil
end

--- The message and stat of a commit, read on first use.
--- @param s gitview.Session
--- @param commit gitview.Commit
--- @param range gitview.Range what it is compared in, which the stat is of
--- @return gitview.CommitDetail?
local function commit_detail(s, commit, range)
  if not kept_detail(s, range) then
    local detail, err = git.commit_detail(commit, range, s.root, stat_width(s))
    if not detail then
      -- the diff under it is still worth showing
      util.git_error(assert(err))
      return nil
    end
    s.details[assert(range_key(range))] = detail
  end
  return s.details[assert(range_key(range))]
end

--- The files in a directory, with their indices, in list order.
--- @generic T: {path:string}
--- @param files T[]
--- @param dir string without a trailing slash; `''` for the root
--- @return T[] files
--- @return integer[] indices
local function files_in(files, dir)
  local prefix = dir == '' and '' or dir .. '/'
  local found, indices = {}, {}
  for i, f in ipairs(files) do
    if f.path:sub(1, #prefix) == prefix then
      found[#found + 1] = f
      indices[#indices + 1] = i
    end
  end
  return found, indices
end

--- Read uncommitted files for one view, as the files pane has them file by
--- file: HEAD, the index and the working tree at once.
---
--- What is read is returned as the function that draws it, so that the reading
--- can be done without blocking and the drawing skipped once nobody wants it.
--- Building the view is left to the drawing: it makes ghost buffers, which a
--- view that is never drawn would have to free.
---
--- Nothing is staged from here. It is many files, and the index contents a
--- partial stage writes back are read for one.
--- @param s gitview.Session
--- @param entries gitview.StatusEntry[] some or all of `s.entries`
--- @return fun() draw
local function read_entries(s, entries)
  if #entries == 0 then
    return function()
      render.notice(s.diff_buf, list.empty_notice(s.layer))
    end
  end
  local sources, skipped = perf.measure('source', source.for_entries, entries, s.root)
  local rev = rev_of(s)
  return function()
    local view, left_out =
      perf.measure('build', vlib.build, sources, rev, config.values.diff_context, diff_opts(s))
    view = vlib.list_skipped(view, rev, skipped, left_out, no_view_reason(s))
    if not view then
      render.notice(s.diff_buf, ('%s   %s'):format(rev, no_view_reason(s)))
      return
    end
    view.note = note_of(s)
    draw_placed(s, view)
  end
end

--- Whether the commits pane shows this commit on its own, rather than as one
--- end of a range.
--- @param s gitview.Session
--- @param commit gitview.Commit?
--- @param range gitview.Range?
--- @return boolean
local function is_whole_commit(s, commit, range)
  return commit ~= nil and range ~= nil and vim.deep_equal(range, (whole_range(s, commit)))
end

--- Read what the commits pane's cursor compares: one commit against its first
--- parent, the stretch between it and the mark, or on the working-tree row by
--- itself, everything uncommitted. Returned as `read_entries` returns it.
---
--- A range is a two-version view: there is no index between the sides and so
--- nothing to mark as staged, even when one side is the working tree.
--- @param s gitview.Session
--- @param target gitview.ListTarget a commit or the working tree
--- @return fun() draw
local function read_commit(s, target)
  local commit = target.kind == 'commit' and s.commits[target.index] or nil
  if target.kind == 'commit' and not commit then
    return function()
      render.notice(s.diff_buf, list.EMPTY_NOTICE)
    end
  end
  local range, label = range_of(s, target, true)
  if not range then
    return read_entries(s, s.entries)
  end
  local read, err = read_range(s, range)
  if not read then
    return function()
      util.git_error(err)
      render.notice(s.diff_buf, label .. '   (could not be read)')
    end
  end
  local note = range_note(s, range, target, read)
  -- A range between two ends has no one message to show.
  local detail = is_whole_commit(s, commit, range)
    and perf.measure('detail', commit_detail, s, assert(commit), range)

  return function()
    local view, left_out =
      perf.measure('build', vlib.build, read.sources, label, config.values.diff_context, diff_opts(s))
    view = vlib.list_skipped(view, label, read.skipped, left_out, no_view_reason(s))
    if not view and detail then
      -- Nothing at all changed, as in an empty commit: there is no file left out
      -- to call unchanged, but the message is still worth reading.
      view = vlib.placeholder(label, NO_CHANGE, vlib.commit_header(detail, assert(commit)))
      view.note = note_of(s, note)
      draw_view(s, view)
      return
    end
    if not view then
      render.notice(s.diff_buf, ('%s   %s'):format(label, no_view_reason(s)))
      return
    end
    view.note = note_of(s, note)
    if detail then
      vlib.prepend(view, vlib.commit_header(detail, assert(commit)))
    end
    draw_view(s, view)
  end
end

--- The part of a range's contents under one directory.
--- @param read gitview.RangeRead
--- @param root string repository root
--- @param dir string without a trailing slash; `''` for the root
--- @return gitview.Source[] sources
--- @return gitview.Skipped skipped
local function range_read_in(read, root, dir)
  if dir == '' then
    return read.sources, read.skipped
  end
  -- Sources are named by absolute path, skipped files by repository path.
  local abs, rel = vim.fs.joinpath(root, dir) .. '/', dir .. '/'
  local sources = vim.tbl_filter(function(src)
    return src.path:sub(1, #abs) == abs
  end, read.sources)
  local function under(path)
    return path:sub(1, #rel) == rel
  end
  local skipped = {
    binary = vim.tbl_filter(under, read.skipped.binary),
    conflicts = vim.tbl_filter(function(c)
      return under(c.path)
    end, read.skipped.conflicts or {}),
  }
  return sources, skipped
end

--- Read a directory of a range. Returned as `read_entries` returns it.
---
--- The whole range is read and kept, and the directory taken out of it: the
--- commit's own row and every other directory in it then share one read.
--- @param s gitview.Session
--- @param target gitview.ListTarget a directory of a scope
--- @return fun() draw
local function read_scope_dir(s, target)
  local scope = scope_of(s, target)
  if not scope then
    return function()
      render.notice(s.diff_buf, list.EMPTY_NOTICE)
    end
  end
  local read, err = read_range(s, scope.range)
  if not read then
    return function()
      util.git_error(err)
      render.notice(s.diff_buf, scope.label .. '   (could not be read)')
    end
  end
  local sources, skipped = range_read_in(read, s.root, assert(target.path))
  return function()
    local moved = see_sources(s, target, sources)
    local view, left_out =
      perf.measure('build', vlib.build, sources, scope.label, config.values.diff_context, diff_opts(s))
    view = vlib.list_skipped(view, scope.label, skipped, left_out, no_view_reason(s))
    if not view then
      render.notice(s.diff_buf, ('%s   %s'):format(scope.label, no_view_reason(s)))
      return
    end
    view.note = note_of(s, scope_note(s, target))
    draw_view(s, view)
    if moved then
      redraw_checks(s)
    end
  end
end

--- Whether a row stands for many files, which take long enough to read that a
--- cursor passing over it should not wait for them.
--- @param target gitview.ListTarget?
--- @return boolean
local function shows_many(target)
  local kind = target and target.kind
  return kind == 'commit' or kind == 'worktree' or kind == 'dir' or kind == 'commit_dir'
end

--- Read what a row standing for many files shows: a commit or the working tree
--- in the commits pane, or a directory of either list. Returned as
--- `read_entries` returns it.
--- @param s gitview.Session
--- @param target gitview.ListTarget a commit, the working tree or a directory
--- @return fun() draw
local function read_many(s, target)
  if target.kind == 'dir' then
    return read_entries(s, (files_in(s.entries, assert(target.path))))
  end
  if target.kind == 'commit_dir' then
    return read_scope_dir(s, target)
  end
  return read_commit(s, target)
end

--- What the diff pane says while a view is being read.
local LOADING = '(loading…)'

--- Whether everything the view of `target` is built from has been read before,
--- so that it can be drawn without running git.
--- @param s gitview.Session
--- @param target gitview.ListTarget a commit, the working tree or a directory
--- @return boolean
local function is_kept(s, target)
  if target.kind == 'commit_dir' then
    local scope = scope_of(s, target)
    local key = scope and range_key(scope.range)
    return key ~= nil and s.range_reads[key] ~= nil
  end
  local commit = target.kind == 'commit' and s.commits[target.index] or nil
  if not commit then
    return false
  end
  local range = range_of(s, target)
  local key = range and range_key(range)
  local read = key and s.range_reads[key]
  if not read then
    return false
  end
  if is_whole_commit(s, commit, range) then
    return kept_detail(s, range) ~= nil
  end
  local older = ends_of(s, target)
  return older == nil or read.diverged[older.sha] ~= nil
end

--- Stand in for the view of a commit, the working tree or a directory until it
--- is read.
---
--- A commit on its own gets its header straight away: in full when its message
--- has been read before, and otherwise as much of it as the log already gave.
--- @param s gitview.Session
--- @param target gitview.ListTarget a commit, the working tree or a directory
local function draw_loading(s, target)
  if target.kind == 'dir' or target.kind == 'commit_dir' then
    local scope = target.kind == 'commit_dir' and scope_of(s, target)
    local label = target.kind == 'dir' and rev_of(s) or (scope and scope.label or '')
    render.draw(s.diff_buf, vlib.placeholder(label, LOADING))
    return
  end
  local commit = target.kind == 'commit' and s.commits[target.index] or nil
  local range, label = range_of(s, target)
  local header
  -- Told by the ends rather than by the range, which a merge whose automatic
  -- merge is not read yet has none of.
  if commit and not ends_of(s, target) then
    local detail = range and s.details[assert(range_key(range))]
    header = detail and vlib.commit_header(detail, commit) or vlib.commit_summary(commit)
  end
  render.draw(s.diff_buf, vlib.placeholder(label, LOADING, header))
end

--- Read the view `s.pending` asks for without blocking, and draw it if it is
--- still wanted once it has been read.
---
--- One view is read at a time. Sweeping the cursor down the list asks for one
--- per row, and all but the last are stale before they could be shown; reading
--- each would only queue git processes behind one another. Whatever is asked
--- for meanwhile replaces what is waiting, and is read once the current read
--- is done.
--- @param s gitview.Session
local function read_pending(s)
  local job = s.pending
  if s.loading or not job then
    return
  end
  s.pending = nil
  -- A draw since the request was made, such as a file row being selected, has
  -- already replaced it.
  if job.generation ~= s.generation then
    job.span:finish({ dropped = true })
    return
  end
  local target = assert(s.selected)
  s.loading = true
  git.async(function()
    return read_many(s, target)
  end, function(draw)
    s.loading = nil
    if M.sessions[s.tab] ~= s or not vim.api.nvim_buf_is_valid(s.diff_buf) then
      job.span:finish({ dropped = true })
      return
    end
    if job.generation == s.generation then
      draw()
      job.span:finish()
    else
      job.span:finish({ dropped = true })
    end
    read_pending(s)
  end)
end

--- Whether a draw asked for at `generation` is still wanted: nothing has been
--- drawn since, and the session is still there to draw into.
--- @param s gitview.Session
--- @param generation integer
--- @return boolean
local function is_wanted(s, generation)
  return s.generation == generation
    and M.sessions[s.tab] == s
    and vim.api.nvim_buf_is_valid(s.diff_buf)
end

--- Draw a commit, or a directory of one, read before on the next turn of the
--- event loop, if it is still selected by then.
---
--- There is nothing to read, but drawing is still the costly part of a large
--- commit. Drawn from `CursorMoved` itself, every such row a sweep passes over
--- would hold the cursor up for its whole draw. A timer rather than
--- `vim.schedule`, so that a keystroke already waiting gets in first and makes
--- the draw stale. No placeholder is drawn: the view takes a moment at most,
--- and a placeholder would only blink before it.
--- @param s gitview.Session
--- @param target gitview.ListTarget a commit, or a directory of one
--- @param span gitview.PerfSpan
local function draw_kept(s, target, span)
  local generation = s.generation
  vim.defer_fn(function()
    if not is_wanted(s, generation) then
      span:finish({ kept = true, dropped = true })
      return
    end
    read_many(s, target)()
    span:finish({ kept = true })
  end, 0)
end

--- Read a view in the background behind a placeholder drawn at once.
--- @param s gitview.Session
--- @param target gitview.ListTarget a commit, the working tree or a directory
--- @param span gitview.PerfSpan finished once the view is drawn or found stale
local function read_behind_placeholder(s, target, span)
  draw_loading(s, target)
  if s.pending then
    s.pending.span:finish({ dropped = true })
  end
  s.pending = { generation = s.generation, span = span }
  read_pending(s)
end

--- How long the cursor has to rest on a directory before its files are read.
--- Long enough to cover a held key's repeat, short enough not to be noticed once
--- the cursor has stopped.
local DIR_WAIT_MS = 100

--- Read a directory in the background once the cursor has rested on it.
---
--- Moving from file to file in a tree passes over directory rows all the time.
--- Reading each would start a read that cannot be stopped and blink a
--- placeholder between two files' views. Until the wait is over the pane keeps
--- the view it had, which the selection no longer names, so nothing done in it
--- reaches the file it shows.
--- @param s gitview.Session
--- @param target gitview.ListTarget a directory
--- @param span gitview.PerfSpan
local function read_dir_later(s, target, span)
  local generation = s.generation
  vim.defer_fn(function()
    if not is_wanted(s, generation) then
      span:finish({ dropped = true })
      return
    end
    read_behind_placeholder(s, target, span)
  end, DIR_WAIT_MS)
end

--- Draw a commit, the working tree or a directory, many files each, either at
--- once or in the background: read behind a placeholder, or for one read
--- before, just drawn a moment later.
--- @param s gitview.Session
--- @param target gitview.ListTarget a commit, the working tree or a directory
--- @param span gitview.PerfSpan? given, the view is drawn in the background,
---        and the span is finished once it is drawn or found to be stale
local function show_many(s, target, span)
  if not span then
    read_many(s, target)()
    return
  end
  if is_kept(s, target) then
    draw_kept(s, target, span)
    return
  end
  if target.kind == 'dir' or target.kind == 'commit_dir' then
    read_dir_later(s, target, span)
    return
  end
  read_behind_placeholder(s, target, span)
end

--- Draw one file of a range.
---
--- This is the same two-version view `show_many` draws, narrowed to one file:
--- one entry of the change list the scope already holds, so nothing has to be
--- listed again.
--- @param s gitview.Session
--- @param target gitview.ListTarget a file of a scope
local function show_commit_file(s, target)
  local scope = scope_of(s, target)
  local change = scope and scope.changes[target.index]
  if not scope or not change then
    render.notice(s.diff_buf, list.EMPTY_NOTICE)
    return
  end
  local label = status.change_label(change)
  if change.binary then
    render.notice(s.diff_buf, ('%s   (binary file)'):format(label))
    return
  end

  local src = perf.measure('source', source.for_range_change, scope.range, change, s.root)
  local moved = src and see_sources(s, target, { src })
  local view = src
    and perf.measure('build', vlib.build, { src }, scope.label, config.values.diff_context, diff_opts(s))
  if not view then
    -- A pure rename or a mode change: a real change with no lines to show. Or
    -- an unmerged file with no conflict marked out.
    local reason = no_view_reason(s)
    if change.status == 'U' then
      reason = '(unresolved conflict with no markers)'
    end
    render.notice(s.diff_buf, ('%s   %s'):format(label, reason))
    return
  end
  view.note = note_of(s, scope_note(s, target))
  draw_view(s, view)
  if moved then
    redraw_checks(s)
  end
end

--- Whether what is selected is compared with the working tree, which can change
--- under a name that stays the same.
--- @param s gitview.Session
--- @return boolean
local function reads_worktree(s)
  local t = s.selected
  if not t then
    return false
  end
  if t.kind == 'commit' then
    return s.mark == list.WORKTREE
  end
  if t.kind == 'commit_file' or t.kind == 'commit_dir' then
    local scope = scope_of(s, t)
    return scope ~= nil and scope.range.new == nil
  end
  return true
end

--- Draw whatever is selected, or say why there is nothing to draw.
---
--- The index contents are kept, since staging writes the chosen rows into them.
---
--- @param s gitview.Session
--- @param keep_unchanged boolean? leave the pane as it is when it already shows
---        what the selection names. Only for a caller that knows the contents
---        cannot have changed; see `refresh`.
--- @param span gitview.PerfSpan? given, a commit, the working tree or a
---        directory is read in the background and the span finished once it is
---        drawn; see `show_many`. Anything else ignores it.
function M.show_selected(s, keep_unchanged, span)
  -- The comparison is by what is shown rather than by the target, because a
  -- refresh can move a file to another index while it goes on being the same
  -- file.
  local id = selection_id(s)

  -- A commit and a range are named by sha, so what they compare cannot have
  -- changed and the view already drawn still stands. Whatever reads the working
  -- tree is named by something that says nothing about the contents — a path,
  -- the working-tree row — and it has to be built again.
  if keep_unchanged and id and not reads_worktree(s) and vim.deep_equal(id, s.shown) then
    return
  end
  s.index_lines = nil

  -- Redrawing the same thing keeps the position in it: that is what staging a
  -- hunk does, and being thrown back to the top on every `s` would make working
  -- down a diff impossible. Anything else is new contents in a reused buffer,
  -- where an inherited position means nothing: it starts at the top, or where
  -- it was last left when it has been shown before. Until it is drawn the pane
  -- holds something else, and no position is kept from it.
  --
  -- With one layer alone, a change to the index adds or takes away rows, so
  -- the row is no longer the line. Unless something has said where to go, the
  -- line is found again.
  if not vim.deep_equal(id, s.shown) then
    save_position(s)
    s.drawn = nil
    s.restoring = true
    reset_view(s)
    s.placing = nil
  elseif s.layer ~= 'both' and not s.placing then
    place_next(s, place.follow)
  end
  s.shown = id
  s.shown_key = id and position_key(s, id)

  local target = s.selected
  if not target then
    local review = s.review
    if review and #review.scope.changes == 0 then
      render.notice(s.diff_buf, list.EMPTY_REVIEW_NOTICE)
      return
    end
    render.notice(s.diff_buf, s.files_notice or list.empty_notice(s.layer))
    return
  end
  if shows_many(target) then
    show_many(s, target, span)
    return
  end
  if target.kind == 'commit_file' then
    show_commit_file(s, target)
    return
  end
  local entry = s.entries[target.index]
  if not entry then
    render.notice(s.diff_buf, list.empty_notice(s.layer))
    return
  end
  if entry.binary then
    render.notice(s.diff_buf, ('%s   (binary file)'):format(status.label(entry)))
    return
  end
  local src = perf.measure('source', source.for_entry, entry, s.root)
  local view = src
    and perf.measure('build', vlib.build, { src }, rev_of(s), config.values.diff_context, diff_opts(s))
  if not view then
    -- A pure rename or a mode change is a real change with no lines to show. An
    -- unmerged file with no conflict marked out is still unresolved until it is
    -- added, which `s` in the list does.
    local reason = no_view_reason(s)
    if entry.conflicted then
      reason = '(unresolved conflict with no markers; staging the file marks it resolved)'
    end
    render.notice(s.diff_buf, ('%s   %s'):format(status.label(entry), reason))
    return
  end
  view.note = note_of(s)
  draw_placed(s, view)
  s.index_lines = src.index_lines
end

--- Color the rows from the mark to the commits pane's cursor, or none while
--- there is no mark or the pane is looking into something.
---
--- The cursor line is turned off meanwhile: its background and the range's
--- would run into each other, and the cursor is still told apart by the color
--- `list.paint_cursor` gives it.
--- @param s gitview.Session
local function paint_range(s)
  local at = not s.scope and place_of(s, s.mark)
  local first, last
  if at then
    local mark_row = list.row_of(
      s.commits_buf,
      at == 0 and { kind = 'worktree', index = 1 } or { kind = 'commit', index = at }
    )
    local cursor_row = vim.api.nvim_win_get_cursor(s.commits_win)[1]
    if mark_row then
      first, last = math.min(mark_row, cursor_row), math.max(mark_row, cursor_row)
    end
  end
  local shown = list.state_of(s.commits_buf)
  local was = shown and shown.range
  list.paint_range(s.commits_buf, first, last)
  if vim.wo[s.commits_win].cursorline ~= (first == nil) then
    util.configure_window_options(s.commits_win, { cursorline = first == nil })
  end
  -- The winbar counts the rows, and nothing else redraws it as the cursor moves.
  -- `nvim__redraw` is not public API and may change; it is the one call that
  -- redraws a single window's winbar.
  if (shown and shown.range) ~= was then
    vim.api.nvim__redraw({ win = s.commits_win, winbar = true })
  end
end

--- Draw whatever the list's cursor is on.
---
--- Following the cursor means skipping the work when it has not left the row it
--- was on, but the first draw and a refresh have to happen regardless: both can
--- leave the selection exactly where it was and still need the pane rebuilt.
---
--- A commit's diff is every file it touched, so reading one in the foreground
--- would stall the cursor on every row passed over on the way somewhere. It is
--- read in the background instead, behind a placeholder drawn at once. A file
--- row costs a single file's view and is drawn at once.
--- @param s gitview.Session
--- @param win integer the window whose cursor decides the selection
--- @param force boolean? draw even when the selection has not moved
--- @param keep_unchanged boolean? passed on to `show_selected`
local function sync_selection(s, win, force, keep_unchanged)
  local buf = vim.api.nvim_win_get_buf(win)
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local target = list.target_at(buf, row)
  -- Painted even when the selection has not moved: a redraw of the list takes
  -- the paint with the lines it replaces.
  list.paint_cursor(buf == s.files_buf and s.commits_buf or s.files_buf, nil)
  list.paint_cursor(buf, row)
  paint_range(s)
  if not force and list.same_target(target, s.selected) then
    return
  end
  s.selected = target
  -- Every draw takes a generation, so one read in the background can tell that
  -- it is no longer wanted.
  s.generation = s.generation + 1
  -- From the cursor landing to the view being on screen: the wait the reader
  -- actually has, whatever it is made of.
  local span = perf.start('select', { gen = s.generation, kind = target and target.kind })

  -- A refresh is an explicit act rather than a cursor sweep, and it redraws
  -- what is already on screen, which a placeholder would only blink over. The
  -- working-tree row and a directory are many files as a commit is, and are
  -- read as one is.
  if force or not shows_many(target) then
    M.show_selected(s, keep_unchanged)
    span:finish()
    return
  end
  M.show_selected(s, keep_unchanged, span)
end

--- Put the list's cursor on the nth file it lists and show it. An index past
--- either end is clamped, so `]f` on the last file stays on the last file.
---
--- Which list that is is the one `like` is in: the uncommitted changes, or the
--- files of a range.
--- @param s gitview.Session
--- @param like gitview.ListTarget a file of the list, only its kind and the
---        list it is in read
--- @param index integer
--- @return boolean moved false when the index was past either end, or the
---         list holds no files
local function select_nth(s, like, index)
  local scope = like.kind == 'commit_file' and scope_of(s, like)
  local count = like.kind == 'file' and #s.entries or #(scope and scope.changes or {})
  if count == 0 then
    return false
  end
  local clamped = math.max(1, math.min(count, index))
  local target = { kind = like.kind, index = clamped, review = like.review } --- @type gitview.ListTarget
  local win, buf = pane_of(s, target)
  local row = list.row_of(buf, target)
  if row then
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end
  -- The cursor now stands on the row that was asked for, so following it is all
  -- that is left to do.
  sync_selection(s, win)
  return clamped == index
end

--- Put the list's cursor on one of the uncommitted files and show it.
--- @param s gitview.Session
--- @param index integer
function M.select(s, index)
  select_nth(s, { kind = 'file', index = 1 }, index)
end

--- What the selection names, in terms that survive a redraw.
---
--- Neither the row nor the index into a list can be used to find the same thing
--- again: the file section changes length, which moves every commit row below
--- it, and a file removed from the list shifts the indices of the rest.
---
--- The reverse of `selection_id` against the lists as they now are.
--- @param s gitview.Session
--- @param id gitview.SelectionId?
--- @return gitview.ListTarget?
local function target_of_id(s, id)
  if not id then
    return nil
  end
  if in_list_away(s, id) then
    return nil
  end
  if id.kind == 'worktree' then
    return has_worktree_row(s) and { kind = 'worktree', index = 1 } or nil
  end
  -- A directory is still there as long as a file in it is.
  local scope = (id.kind == 'commit_file' or id.kind == 'commit_dir') and scope_of(s, id)
  if id.kind == 'dir' or id.kind == 'commit_dir' then
    local files = id.kind == 'dir' and s.entries or (scope and scope.changes or {})
    local _, indices = files_in(files, id.id)
    return indices[1] and { kind = id.kind, index = indices[1], path = id.id, review = id.review }
      or nil
  end
  local haystack, name
  if id.kind == 'file' then
    haystack, name = s.entries, 'path'
  elseif id.kind == 'commit' then
    haystack, name = s.commits, 'sha'
  else
    haystack, name = scope and scope.changes or {}, 'path'
  end
  for i, it in ipairs(haystack) do
    if it[name] == id.id then
      return { kind = id.kind, index = i, review = id.review }
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

--- What the files pane shows: the uncommitted files, or the review's.
--- @param s gitview.Session
--- @return gitview.ListModel
local function files_model(s)
  return {
    pane = 'files',
    root = s.root,
    entries = s.entries,
    review = s.review,
    notice = s.files_notice,
    layer = s.layer,
    tree = config.values.file_list_style == 'tree',
  }
end

--- Draw again what a review's checks change: the files pane, and the marks on
--- the diff's headers. Nothing is read and the diff is not drawn again, so a
--- view of many files is not built anew on every check.
--- @param s gitview.Session
function redraw_checks(s)
  list.draw(s.files_buf, files_model(s))
  -- The paint went with the lines it was on.
  if s.selected and s.selected.review then
    list.paint_cursor(s.files_buf, vim.api.nvim_win_get_cursor(s.files_win)[1])
  end
  vim.api.nvim__redraw({ win = s.files_win, winbar = true })
  paint_checks(s)
end

--- Draw both panes of the sidebar from the session's state, and put the cursor
--- on `target`.
---
--- Failing that — the file was committed away, say — each pane keeps the row it
--- was on, and the selection is taken from whichever pane it was already in.
---
--- @param s gitview.Session
--- @param target gitview.ListTarget? where the cursor should end up
--- @param keep_unchanged boolean? passed on to `show_selected`
local function redraw_list(s, target, keep_unchanged)
  local as_tree = config.values.file_list_style == 'tree'
  list.draw(s.files_buf, files_model(s))
  list.draw(s.commits_buf, {
    pane = 'commits',
    root = s.root,
    commits = s.commits,
    worktree = has_worktree_row(s),
    scope = s.scope,
    listing = s.review and s.listing or nil,
    stale = s.commits_stale,
    tree = as_tree,
  })
  paint_upstream(s)
  clamp_cursor(s.files_win)
  clamp_cursor(s.commits_win)

  local from = target or s.selected
  local win, buf = pane_of(s, from or { kind = 'file', index = 1 })
  local row = target and list.row_of(buf, target)
  if row then
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end

  -- The row under the cursor may now be a different file, or the same file with
  -- different contents, so the diff is rebuilt either way unless the caller says
  -- it knows better.
  sync_selection(s, win, true, keep_unchanged)
end

--- Clear a mark whose row has gone.
---
--- A mark on a commit that has dropped off the end of the list, or on the
--- working-tree row while the status cannot be read, would go on widening every
--- range while no row showed where it was. It is only ever cleared along with the list
--- it pointed into.
--- @param s gitview.Session
local function drop_lost_mark(s)
  if s.mark and not place_of(s, s.mark) then
    s.mark = nil
  end
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
--- Does nothing while an autosquash runs; the read when it ends covers what is
--- skipped.
---
--- @param s gitview.Session
--- @param id gitview.SelectionId? what is selected, named before the re-read
local function read_log(s, id)
  if s.autosquash then
    return
  end
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
  reread_upstream(s)
  s.commits_stale = nil
  drop_lost_mark(s)
end

--- List again what a range ending at the working tree changed, since the working
--- tree may have moved on. A range between commits cannot have, and is left as
--- it is; so is the list when it cannot be read, being the best there is.
--- Does nothing while an autosquash runs; the read when it ends covers what is
--- skipped.
--- @param s gitview.Session
--- @param scope gitview.ListScope
local function reread_scope(s, scope)
  if scope.range.new or s.autosquash then
    return
  end
  local changes = git.changed_between(scope.range, s.root, untracked_paths(s))
  if changes then
    scope.changes = changes
  end
end

--- Take the checks off the files under review that are unmerged now, since
--- what was read of one is not what resolving it will leave. A conflict with
--- no markers, as a modify/delete one, can still match what was read, and its
--- check would otherwise hold while the conflict is open.
--- @param s gitview.Session
local function uncheck_conflicts(s)
  local r = assert(s.review)
  for _, c in ipairs(r.scope.changes) do
    if c.status == 'U' then
      r.checks[c.path] = nil
    end
  end
end

--- Note what every file checked off in a review ending at the working tree is
--- now, whether the review still lists it or not: one put back as it was and
--- changed again is checked once it is as it was read.
---
--- Every one is read again, with no shortcut such as its modification time:
--- a change missed would leave what has not been read marked as read, the worst
--- way for a review to be wrong.
--- @param s gitview.Session
local function see_files(s)
  local r = assert(s.review)
  if r.scope.range.new then
    return
  end
  for path, c in pairs(r.checks) do
    review.see(r.checks, path, review.hash_file(vim.fs.joinpath(s.root, path), c.binary))
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
--- Does nothing while an autosquash runs; the read when it ends covers what is
--- skipped.
---
--- @param s gitview.Session
--- @param report boolean whether to tell the user when git fails
--- @param keep_unchanged boolean? passed on to `show_selected`
--- @param follow? {from:gitview.SelectionId, to:gitview.SelectionId} what to
---        select in place of `from`, should it still be selected once read: the
---        commit an autosquash rewrote, which would otherwise hold the old list
---        open
local function read_status(s, report, keep_unchanged, follow)
  if s.autosquash then
    return
  end
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
    -- Follow only while the original is still selected and no range is being
    -- chosen: what the user went on to look at meanwhile is theirs to keep.
    if follow and not s.mark and vim.deep_equal(id, follow.from) then
      id = follow.to
    end
    -- The first list read puts the cursor on the first file rather than the
    -- first row, which in a tree is the root and shows nothing.
    local first = s.files_notice ~= nil and #s.entries == 0
    s.uncommitted = entries
    s.entries = in_layer(entries, s.layer)
    s.files_notice = nil
    s.outdated = nil
    -- While a range is being looked into, the commits pane shows its files and
    -- the list behind them is off screen, so re-reading it would buy nothing.
    -- Backing out is what reads it again.
    if not s.scope then
      read_log(s, id)
    else
      reread_scope(s, s.scope)
    end
    -- A review is in the files pane, and is re-read whatever the commits pane
    -- is showing.
    if s.review then
      reread_scope(s, s.review.scope)
      uncheck_conflicts(s)
      see_files(s)
    end
    -- The working-tree row comes and goes with the entries, and its mark with it.
    drop_lost_mark(s)
    local target = target_of_id(s, id)
    if not target and first and #s.entries > 0 then
      target = { kind = 'file', index = 1 }
    end
    redraw_list(s, target, keep_unchanged)
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
--- A range ending at the working tree is the exception, and its files are listed
--- again.
---
--- @param s gitview.Session
--- @param opts? {auto?:boolean} `auto` for a refresh nothing asked for. It is
---        throttled, it says nothing when git fails, since the trigger will come
---        again and a message per attempt would be noise, and it leaves the diff
---        pane alone when what it shows cannot have changed.
function M.refresh(s, opts)
  local auto = opts and opts.auto or false
  -- Skip while an autosquash runs, saying so only when asked: it reads
  -- everything again when it ends.
  if s.autosquash then
    if not auto then
      util.info('an autosquash is running; the repository is read again once it ends')
    end
    return
  end
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
--- @param s gitview.Session
--- @param win integer the window whose cursor decides the selection
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
--- @param s gitview.Session
function M.toggle_whitespace(s)
  M.set_whitespace(s, not s.ignore_whitespace)
end

--- Count lines that differ only in whitespace as unchanged, or as changed.
---
--- The view is rebuilt rather than redrawn, because which lines differ is what
--- changed. The position in it is kept: it is the same file being read.
--- @param s gitview.Session
--- @param ignore boolean
--- @return boolean changed false when they were counted so already
function M.set_whitespace(s, ignore)
  if s.ignore_whitespace == ignore then
    return false
  end
  s.ignore_whitespace = ignore
  s.generation = s.generation + 1
  M.show_selected(s)
  return true
end

--- Show the next layer of the uncommitted changes: both, staged alone, or
--- unstaged alone, and round again.
--- @param s gitview.Session
function M.toggle_layer(s)
  M.set_layer(s, NEXT_LAYER[s.layer])
end

--- Show both layers of the uncommitted changes, or one alone.
---
--- A file the list goes on showing stays selected, and the diff's cursor stays
--- on the line it was on, though every row of it may have moved. A file the
--- list no longer shows gives way to its first file: where the cursor was in
--- the old list means nothing in the new one.
--- @param s gitview.Session
--- @param layer gitview.Layer
--- @return boolean handled false when the layer is shown already
function M.set_layer(s, layer)
  if s.layer == layer then
    return false
  end
  -- A review compares two trees, with no index between them, so nothing it
  -- shows would change. What would is the files pane once the review is over,
  -- left filtered by a switch made while it could not be seen.
  if s.review then
    util.info('the shown changes cannot be switched during a review')
    return true
  end
  local id = selection_id(s)
  place_next(s, place.same_line)
  s.layer = layer
  s.entries = in_layer(s.uncommitted, s.layer)
  s.generation = s.generation + 1
  local target = target_of_id(s, id)
  if not target and id and (id.kind == 'file' or id.kind == 'dir') and #s.entries > 0 then
    target = { kind = 'file', index = 1 }
  end
  redraw_list(s, target)
  return true
end

--- The row of the commits pane the cursor is on, and what a mark on it would
--- hold, or nil when it is on neither a commit nor the working tree.
--- @param s gitview.Session
--- @return gitview.ListTarget?
--- @return string? mark a sha, or `list.WORKTREE`
local function selected_end(s)
  local target = s.selected
  if target and target.kind == 'worktree' then
    return target, list.WORKTREE
  end
  local commit = target and target.kind == 'commit' and s.commits[target.index]
  if not commit then
    return nil, nil
  end
  return target, commit.sha
end

--- Mark the commit under the cursor, moving the mark there if it is elsewhere.
---
--- One mark rather than two: the far end is marked and the near end is wherever
--- the cursor goes, so a range is read by moving rather than by a second key.
--- The commits pane is short and a range is often long, which is what makes
--- moving the better half to leave free.
---
--- Marking never clears, even on the mark itself: starting a range somewhere
--- else is then one key wherever the cursor is, and clearing has a key of its
--- own, `clear_mark`.
---
--- @param s gitview.Session
--- @return boolean marked false when the cursor is on no commit
function M.set_mark(s)
  local target, mark = selected_end(s)
  if not target then
    return false
  end
  s.mark = mark
  redraw_list(s, target)
  return true
end

--- Clear the mark, if there is one.
--- @param s gitview.Session
--- @return boolean cleared false when there was nothing to clear
function M.clear_mark(s)
  if not s.mark then
    return false
  end
  s.mark = nil
  redraw_list(s, s.selected)
  return true
end

--- Replace the commits pane with the files a range changed, the cursor on the
--- first of them.
--- @param s gitview.Session
--- @param range gitview.Range
--- @param label string
--- @param at string what backing out puts the cursor back on
--- @param first string? see `gitview.ListScope`
local function look_into(s, range, label, at, first)
  local changes, err = git.changed_between(range, s.root, untracked_paths(s))
  if not changes then
    util.git_error({ what = 'git diff ' .. label, stderr = err or '' })
    return
  end
  s.scope = { range = range, label = label, at = at, first = first, changes = changes }
  redraw_list(s, { kind = 'commit_file', index = 1 })
end

--- Look into the commit under the cursor: its files replace the list, and
--- selecting one shows that file's diff by itself.
---
--- The change list is read once, here, and kept: it is what the rows stand for
--- and what each file's versions are then read against.
---
--- The working tree on its own has nothing to look into that the files pane does
--- not already list, so there the cursor goes to the files pane instead.
---
--- @param s gitview.Session
--- @return boolean handled false when already looking into one, or when the
---         cursor is on no commit
function M.enter(s)
  if s.scope then
    return false
  end
  local target, at = selected_end(s)
  if not target then
    return false
  end
  local range, label = range_of(s, target, true)
  if not range then
    if s.review then
      util.info('the uncommitted files are not listed during a review')
      return true
    end
    vim.api.nvim_set_current_win(s.files_win)
    return true
  end
  look_into(s, range, label, assert(at), first_of(s, target))
  return true
end

--- Stop looking into the range, and name the row the commits pane goes back to:
--- the one it was looked into from.
--- @param s gitview.Session
--- @param scope gitview.ListScope the one being looked into
--- @return gitview.SelectionId
local function close_scope(s, scope)
  s.scope = nil
  local kind = scope.at == list.WORKTREE and 'worktree' or 'commit'
  local listed = s.listing == 'review' or nil
  local id = { kind = kind, id = assert(scope.at), in_review_list = listed } --- @type gitview.SelectionId
  -- The list went unread while the range's files stood in front of it, and it may
  -- have moved on since. Reading it here is also what decides whether the commit
  -- being backed out onto is still in it.
  read_log(s, id)
  return id
end

--- Go back to the uncommitted changes, with the cursor on the commit that was
--- being looked into.
--- @param s gitview.Session
--- @return boolean left false when nothing was being looked into
function M.leave(s)
  local scope = s.scope
  if not scope then
    return false
  end
  redraw_list(s, target_of_id(s, close_scope(s, scope)))
  return true
end

--- What the commits pane's cursor is on.
--- @param s gitview.Session
--- @return gitview.SelectionId?
local function commits_cursor_id(s)
  return id_of(s, list.target_at(s.commits_buf, vim.api.nvim_win_get_cursor(s.commits_win)[1]))
end

--- The state of the list the commits pane shows, to put away while the other
--- one is shown.
--- @param s gitview.Session
--- @param at gitview.SelectionId? the row the cursor is on
--- @return gitview.CommitList
local function put_away(s, at)
  return { commits = s.commits, stale = s.commits_stale, mark = s.mark, scope = s.scope, at = at }
end

--- Make a list put away the one the commits pane shows, read again as `refresh`
--- would: it went unread while away.
--- @param s gitview.Session
--- @param l gitview.CommitList
--- @return gitview.ListTarget? target the row its cursor was on, if still there
local function restore_list(s, l)
  s.commits, s.commits_stale, s.mark, s.scope = l.commits, l.stale, l.mark, l.scope
  if s.scope then
    reread_scope(s, s.scope)
  else
    read_log(s, l.at)
  end
  return target_of_id(s, l.at)
end

--- Empty the list the commits pane shows, for a new one to be read into.
--- @param s gitview.Session
local function clear_list(s)
  s.commits, s.commits_stale, s.mark, s.scope = {}, nil, nil, nil
end

--- Refuse while an autosquash runs, saying why.
--- @param s gitview.Session
--- @return boolean refused
local function refuses_autosquashing(s)
  if not s.autosquash then
    return false
  end
  util.info('an autosquash is running; try again once it ends')
  return true
end

--- Whether to go on with what throws the review's checks away, asking first
--- when the review is part way through. A finished one is not asked about: that
--- is how a review ordinarily ends, and asking there every time would make
--- answering yes a habit by the time it matters. No is the default, so `<CR>`
--- and `<Esc>` keep the checks.
--- @param s gitview.Session
--- @return boolean
local function may_discard(s)
  local r = s.review
  if not r or next(r.checks) == nil or review.is_done(r.checks, review_paths(r)) then
    return true
  end
  local question = ('Discard %s?'):format(util.counted(vim.tbl_count(r.checks), 'check'))
  -- Ask with `vim.fn.confirm` rather than `vim.ui.select`, which a plugin may
  -- replace with something that looks different everywhere.
  return vim.fn.confirm(question, '&Yes\n&No', 2) == 1
end

--- Review a range: its files take the place of the uncommitted ones in the files
--- pane, which gets the focus. The range's ends are to be fixed by sha already.
---
--- The mark is cleared: the range is the review's now, and a range still
--- painted in the commits pane would look like one still being chosen.
--- @param s gitview.Session
--- @param range gitview.Range
--- @param label string
--- @param first string? see `gitview.ListScope`
--- @param leave_scope boolean? whether to stop looking into the range the
---        commits pane shows, which is the one reviewed
local function begin_review(s, range, label, first, leave_scope)
  -- Refuse while an autosquash runs: the review's commits are read from the
  -- log, which is not read meanwhile.
  if refuses_autosquashing(s) then
    return
  end
  if not may_discard(s) then
    return
  end
  local changes, err = git.changed_between(range, s.root, untracked_paths(s))
  if not changes then
    util.git_error({ what = 'git diff ' .. label, stderr = err or '' })
    return
  end
  -- Tell whether the range spans a fork once, here: the ends are fixed, and so
  -- is whether they are on one line.
  local note
  if first and not git.is_ancestor(first, range.new or 'HEAD', s.root) then
    note = 'diverged'
  end
  -- Keep what the files pane goes back to at the end from before the first
  -- review, when this one starts over another.
  local before
  if s.review then
    before = s.review.before
  else
    local row = vim.api.nvim_win_get_cursor(s.files_win)[1]
    before = id_of(s, list.target_at(s.files_buf, row))
  end
  -- Put the log away to come back to at the end. Starting over another review
  -- leaves it where it is: away, or shown when this one starts from it.
  if s.listing == 'log' then
    s.mark = nil
    local at = leave_scope and close_scope(s, assert(s.scope)) or commits_cursor_id(s)
    s.away = put_away(s, at)
  end
  -- List every commit for a range from the empty tree, which starts at a root
  -- commit and so leaves no history out.
  local from = range.old
  if from == s.empty_tree then
    from = nil
  end
  s.review = {
    scope = { range = range, label = label, first = first, changes = changes },
    note = note,
    checks = {},
    before = before,
    from = from,
    on_head = not range.new or git.is_ancestor(range.new, 'HEAD', s.root),
  }
  s.listing = 'review'
  clear_list(s)
  read_log(s, nil)
  redraw_list(s, { kind = 'commit_file', index = 1, review = true })
  vim.api.nvim_win_set_cursor(s.commits_win, { 1, 0 })
  -- Focus the files pane only once drawn, so that entering it finds the
  -- review's files there rather than drawing the uncommitted ones on the way.
  vim.api.nvim_set_current_win(s.files_win)
end

--- Review what the commits pane compares, as `<CR>` would look into it. A range
--- being looked into is reviewed instead, and looking into it ends, since the
--- same files would be listed twice.
---
--- The working tree on its own is reviewed from the commit HEAD is on now, and
--- that commit is the one named from then on, so that what is committed while
--- the review goes on stays in it.
--- @param s gitview.Session
--- @return boolean handled false when the cursor is on no commit, or the
---         working tree has no commit to be reviewed from
function M.start_review(s)
  -- Refuse in the review's list, where a review started would look like one
  -- nested in this one, with `<BS>` going back to it, which it is not.
  if s.listing == 'review' then
    util.info('a review is started from the log; switch to it with gl')
    return true
  end
  local scope = s.scope
  if scope then
    begin_review(s, scope.range, scope.label, scope.first, true)
    return true
  end
  local target = selected_end(s)
  if not target then
    return false
  end
  local range, label = range_of(s, target)
  if not range then
    local head = git.head(s.root)
    if not head then
      return false
    end
    range, label = { old = head.full_sha }, head.sha .. '..working tree'
  end
  begin_review(s, range, label, first_of(s, target))
  return true
end

--- Review what `new` changed since it left `base`: from where the two meet to
--- `new`, or to the working tree when there is no `new`. This is what `git diff
--- base...new` compares, and what a pull request on GitHub shows.
---
--- Both ends are fixed by sha here, as every review's are, so that a ref moving
--- meanwhile does not change the range. A range being looked into is left as
--- it is, since it is not the one reviewed.
---
--- It is reviewed in the session of the current tab page, or else in the one
--- `open` goes to or opens. A revision that names no commit opens nothing.
--- @param base string a revision, as the user typed it
--- @param new string? a revision; nil for the working tree
function M.review_refs(base, new)
  -- Resolve the revisions before opening a session, so that a mistyped one
  -- leaves no new tab page behind.
  local s = M.current()
  local root = s and s.root or source.repo_root()
  if not root then
    return
  end
  local base_sha = git.resolve_commit(base, root)
  if not base_sha then
    util.warn(('%s is not a commit'):format(base))
    return
  end
  local new_sha = git.resolve_commit(new or 'HEAD', root)
  if not new_sha then
    util.warn(('%s is not a commit'):format(new or 'HEAD'))
    return
  end
  local from = git.merge_base(base_sha, new_sha, root)
  if not from then
    util.warn(('%s and %s have no history in common'):format(base, new or 'HEAD'))
    return
  end
  s = s or M.open()
  if not s then
    return
  end
  local range = { old = from, new = new and new_sha or nil } --- @type gitview.Range
  -- Give no older end to tell a fork by, since the range starts at a commit as
  -- it stands rather than at a parent, and so never spans a fork.
  begin_review(s, range, ('%s...%s'):format(base, new or 'working tree'))
end

--- End the review, and list the uncommitted files again with the cursor where
--- it was before. The checks go with it, once it is confirmed; see
--- `may_discard`.
--- @param s gitview.Session
--- @return boolean handled false when there was no review
function M.end_review(s)
  local r = s.review
  if not r then
    return false
  end
  if not may_discard(s) then
    return true
  end
  -- The log is shown again as it was left, whichever list is shown now.
  local log = s.listing == 'log' and put_away(s, commits_cursor_id(s)) or assert(s.away)
  s.review, s.away, s.listing = nil, nil, 'log'
  local back = restore_list(s, log)
  local target = target_of_id(s, r.before)
  if not target and #s.entries > 0 then
    target = { kind = 'file', index = 1 }
  end
  redraw_list(s, target)
  local row = back and list.row_of(s.commits_buf, back)
  if row then
    vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
  end
  return true
end

--- Switch the commits pane between the review's list and the log, each as it
--- was left: its cursor, its mark and what it looks into. The diff pane shows
--- what the list switched to has selected.
--- @param s gitview.Session
function M.switch_list(s)
  if not s.review then
    util.info('the log is the only list outside a review')
    return
  end
  local there = assert(s.away)
  s.away = put_away(s, commits_cursor_id(s))
  s.listing = s.listing == 'log' and 'review' or 'log'
  local target = restore_list(s, there)
  if not target then
    target = has_worktree_row(s) and { kind = 'worktree', index = 1 } or { kind = 'commit', index = 1 }
  end
  redraw_list(s, target)
end

--- Fold the `fixup!` and `amend!` commits from the commit under the commits
--- pane's cursor up to HEAD into the commits they name; see `gitview.autosquash`.
---
--- It runs in the background, and until it ends nothing is read from the
--- repository, whatever asks: a rebase half done is not worth drawing, and
--- drawing it would move the lists under the cursor. Once it ends, failing
--- included, everything is read again, and the selection moves to the commit it
--- started from as rewritten, unless the user has moved on to something else.
--- @param s gitview.Session
--- @return boolean handled false when the cursor is on no commit
function M.autosquash(s)
  if refuses_autosquashing(s) then
    return true
  end
  -- Refuse while the status is being read: `git status` may hold the index
  -- lock, which would fail the rebase.
  if s.reading then
    util.info('the status is being read; try again in a moment')
    return true
  end
  if s.scope then
    util.info('back out of the commit first')
    return true
  end
  local target = list.target_at(s.commits_buf, vim.api.nvim_win_get_cursor(s.commits_win)[1])
  if target and target.kind == 'worktree' then
    util.info('an autosquash starts from a commit')
    return true
  end
  local commit = target and target.kind == 'commit' and s.commits[target.index]
  if not commit then
    return false
  end
  if s.mark then
    util.info('clear the range first')
    return true
  end
  local ends = {}
  if s.review then
    local range = s.review.scope.range
    ends[#ends + 1] = range.old
    -- Leave out a newer end that is the working tree: it is no commit to
    -- rewrite.
    if range.new then
      ends[#ends + 1] = range.new
    end
  end
  local from = assert(id_of(s, target))
  s.autosquash = { from = from }
  local root = s.root
  git.async(function()
    return autosquash.run(commit.full_sha, ends, root)
  end, function(res)
    if M.sessions[s.tab] ~= s then
      return
    end
    s.autosquash = nil
    local follow
    if res.refused then
      util.info('not autosquashed: ' .. res.refused)
    elseif res.failed then
      util.git_error({ what = 'git rebase --autosquash', stderr = res.failed })
    elseif res.moved then
      util.info(('autosquashed (HEAD was %s)'):format(res.was))
    else
      util.info('nothing to squash')
    end
    -- Select the rewritten commit in place of the original, which the log may
    -- have dropped: the old list would be held open for it otherwise, hiding
    -- where a rebase that stopped has stopped.
    if res.start then
      local to = { kind = 'commit', id = res.start.sha, in_review_list = from.in_review_list }
      follow = { from = from, to = to }
    end
    -- Read even when nothing was run: whatever changed meanwhile went unread.
    read_status(s, true, false, follow)
  end)
  return true
end

--- Where the commit being looked into sits in the list, or nothing when the
--- scope is a range of several, which has no one place to step from.
---
--- Whether it is a range is read from what the scope compares rather than from
--- the mark, which `<Esc>` can clear while the scope stands.
--- @param s gitview.Session
--- @param scope gitview.ListScope
--- @return integer?
local function scope_place(s, scope)
  local commit, at = commit_by_sha(s, scope.at)
  if is_whole_commit(s, commit, scope.range) then
    return at
  end
  return nil
end

--- Show the row above or below the selected one in the commits list, as `j` and
--- `k` would there, without leaving the diff. `dir` follows the list, which is
--- newest first, so 1 is the older side.
---
--- With a mark set only the cursor's end moves, so the range grows or shrinks
--- as it does under `j` and `k`.
---
--- Looking into a commit, the adjacent commit is looked into instead, from its
--- first file: reading a series one commit at a time would otherwise take
--- backing out, moving and going in again at every step. The working tree on its
--- own is not looked into, so there the list ends at the newest commit.
--- @param s gitview.Session
--- @param dir 1|-1
function M.step_commit(s, dir)
  local scope = s.scope
  local place, first
  -- Refuse while a file under review is shown: it is no commit, nor in one the
  -- commits pane is on, so there is none to step from.
  if s.selected and s.selected.review then
    util.info('no commit is shown')
    return
  end
  if scope then
    place = scope_place(s, scope)
    if not place then
      util.info('a range has no commit next to it')
      return
    end
    first = 1
  else
    local t = s.selected
    if not t or (t.kind ~= 'commit' and t.kind ~= 'worktree') then
      util.info('no commit is shown')
      return
    end
    place = t.kind == 'worktree' and 0 or t.index
    first = has_worktree_row(s) and 0 or 1
  end

  local to = place + dir
  if to < first or to > #s.commits then
    util.info(dir > 0 and 'no older commit in the list' or 'no newer commit in the list')
    return
  end

  if scope then
    local commit = s.commits[to]
    local label = ('%s %s'):format(commit.sha, commit.subject)
    look_into(s, assert((whole_range(s, commit, true))), label, commit.sha, commit.sha)
    return
  end
  local target = to == 0 and { kind = 'worktree', index = 1 } or { kind = 'commit', index = to }
  local row = list.row_of(s.commits_buf, target)
  if row then
    vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
  end
  M.follow_cursor(s, s.commits_win)
end

--- Something the diff pane showed while the cursor was in it.
--- @class gitview.Focused
--- @field id gitview.SelectionId
--- @field key string `id` and what it was compared in; see `position_key`

--- Note what the diff pane shows as focused, for `show_last_focused` to go
--- back to.
---
--- Only what the cursor has been in the diff pane on counts. The diff follows the
--- list's cursor, so counting everything shown would have a sweep over the
--- commits make the row next to the last one the thing to go back to.
--- @param s gitview.Session
function M.note_focused(s)
  local id, key = s.shown, s.shown_key
  if not (id and key) or (s.focused[1] and s.focused[1].key == key) then
    return
  end
  s.focused = { { id = id, key = key }, s.focused[1] }
end

--- Show again what the diff pane was focused on before what it shows now, so
--- that doing it again comes back.
---
--- The list's cursor is put on it, which is what the diff follows, and the focus
--- stays where it is. The commits pane is switched to the list it was in, if
--- that is the one put away. It is refused when no row names it as it was: a file
--- committed since, or one of a commit no longer looked into, which would
--- otherwise have to be looked into again behind the user's back.
--- @param s gitview.Session
function M.show_last_focused(s)
  M.note_focused(s)
  local before = s.focused[2]
  if not before then
    util.info('no other diff has been focused')
    return
  end
  local switched = s.review ~= nil and in_list_away(s, before.id)
  if switched then
    M.switch_list(s)
  end
  local target = target_of_id(s, before.id)
  local win, buf = pane_of(s, before.id)
  local row = target and position_key(s, before.id) == before.key and list.row_of(buf, target)
  if not row then
    -- Leave the commits pane on the list it was on, as a refusal should.
    if switched then
      M.switch_list(s)
    end
    util.info('the diff focused before is no longer listed')
    return
  end
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  M.follow_cursor(s, win)
  M.note_focused(s)
end

--- @param s gitview.Session
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
    -- From the files pane, the last to go, so that closing the others never
    -- moves the cursor: entering a pane follows its cursor into the commits
    -- pane, which may be gone by then.
    if vim.api.nvim_win_is_valid(s.files_win) then
      vim.api.nvim_set_current_win(s.files_win)
    end
    for _, win in ipairs({ s.diff_win, s.commits_win }) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    vim.cmd.quit()
  end
end

--- Open a file of the working tree in the tab page the session was opened from,
--- leaving the session as it is.
---
--- The point is a look at the whole file while reading its diff, so the session
--- stays open to come back to. The file goes into whichever window that tab page
--- last had the cursor in; if that window cannot take it — it is pinned to its
--- buffer, or holds unsaved changes — the error says so there. A tab page closed
--- since is replaced by a new one just before the session's, which later files
--- then go to as well.
---
--- The line may come from a commit, and so name a line of the file as it was
--- then. That is accepted: it is usually close, and the file is what was asked for.
--- @param s gitview.Session
--- @param path string absolute
--- @param lnum integer
--- @param at? { winline: integer, col: integer, text: string? } see `keymap.edit_at`
function M.open_file(s, path, lnum, at)
  if vim.fn.filereadable(path) == 0 then
    util.warn(('%s is not in the working tree'):format(vim.fs.relpath(s.root, path) or path))
    return
  end
  if vim.api.nvim_tabpage_is_valid(s.origin) then
    vim.api.nvim_set_current_tabpage(s.origin)
  else
    vim.api.nvim_set_current_tabpage(s.tab)
    vim.cmd('-tabnew')
    s.origin = vim.api.nvim_get_current_tabpage()
  end
  local ok, err = pcall(keymap.edit_at, path, lnum, at)
  if not ok then
    -- `vim.cmd` wraps the Ex error in where it was raised from, which says
    -- nothing to the user.
    local msg = tostring(err)
    util.warn(msg:match('Vim:(.*)$') or msg)
  end
end

--- Open the file the list's cursor is on; see `open_file`.
--- @param s gitview.Session
--- @param win integer the pane the key was pressed in
function M.open_listed(s, win)
  local buf = vim.api.nvim_win_get_buf(win)
  local target = list.target_at(buf, vim.api.nvim_win_get_cursor(win)[1])
  local item
  if target and target.kind == 'file' then
    item = s.entries[target.index]
  elseif target and target.kind == 'commit_file' then
    local scope = scope_of(s, target)
    item = scope and scope.changes[target.index]
  end
  if target and target.kind == 'worktree' then
    util.info('the uncommitted changes are many files; open one from the files window')
    return
  end
  if target and (target.kind == 'dir' or target.kind == 'commit_dir') then
    util.info('a directory is many files; open one of them')
    return
  end
  if not item then
    util.info('a commit is many files; look into it with <CR> to open one')
    return
  end
  -- A renamed file is opened under its new name, which is the one it has now.
  M.open_file(s, vim.fs.joinpath(s.root, item.path), 1)
end

--- Refuse to stage from a review, saying why. The files are a range's, which
--- has no index between its two sides, and the files pane they sit in is where
--- staging is done otherwise.
--- @param target gitview.ListTarget?
--- @return boolean refused
local function refuses_review(target)
  if not (target and target.review) then
    return false
  end
  util.info('nothing is staged during a review')
  return true
end

--- Refuse to stage from panes the session has made out of date, or while an
--- autosquash is writing the index, saying why.
--- @param s gitview.Session
--- @return boolean refused
local function wait_for_read(s)
  if refuses_autosquashing(s) then
    return true
  end
  if not s.outdated then
    return false
  end
  util.info('the status is being re-read; try again in a moment, or refresh')
  return true
end

--- Change the index for the file or directory under the cursor, then redraw.
---
--- Both panes are rebuilt from git rather than adjusted in place: the status
--- letters, the file's three versions and which lines count as staged all move
--- together, and re-reading is what keeps them agreeing.
---
--- The cursor is left on the row it was on. With both layers shown, staging or
--- unstaging never removes a file from the list — it still differs from HEAD
--- either way — and the list is ordered by path, so the row goes on meaning the
--- same file. With one alone, a file left with no change in it drops out of the
--- list, and the row moves on to the next file, the next to work through.
---
--- A directory's row takes the files the list shows under it, and none that the
--- layer hides: what the row stands for is what is on screen.
---
--- @param s gitview.Session
--- @param op 'stage'|'unstage'
--- @return boolean handled false when the cursor is on nothing to stage
function M.apply_to_selected(s, op)
  local target = s.selected
  if not target then
    return false
  end
  if wait_for_read(s) or refuses_review(target) then
    return true
  end
  local action, why
  if target.kind == 'dir' then
    local entries = files_in(s.entries, assert(target.path))
    local name = list.dir_label(assert(target.path))
    if op == 'stage' then
      action, why = stage.stage_all(entries, name)
    else
      action, why = stage.unstage_all(entries, s.has_head, name)
    end
  elseif target.kind == 'file' then
    local entry = s.entries[target.index]
    if not entry then
      return false
    end
    if op == 'stage' then
      action, why = stage.stage(entry)
    else
      action, why = stage.unstage(entry, s.has_head)
    end
  else
    util.info('only an uncommitted file can be staged')
    return true
  end
  if not action then
    util.info(why or 'nothing to do')
    return true
  end
  local err = stage.run(action, s.root)
  if err then
    util.git_error(err)
    return true
  end
  s.outdated = true
  M.refresh(s)
  return true
end

--- Change the index for the files under the rows `first` to `last` of the
--- files pane, then redraw; see `apply_to_selected`, which a single row is
--- left to.
---
--- Rows of directories take the files the list shows under them. The files are
--- staged together, as a directory's are, so that an unmerged one among them
--- refuses them all: staging it is how its conflict is marked resolved, which
--- is done file by file.
--- @param s gitview.Session
--- @param op 'stage'|'unstage'
--- @param first integer 1-based
--- @param last integer inclusive
--- @return boolean handled false when the rows stand for no file
function M.apply_to_list_rows(s, op, first, last)
  if first == last then
    return M.apply_to_selected(s, op)
  end
  local entries, seen = {}, {}
  for row = first, last do
    local t = list.target_at(s.files_buf, row)
    if t and t.review then
      refuses_review(t)
      return true
    end
    local found = {}
    if t and t.kind == 'file' then
      found = { s.entries[t.index] }
    elseif t and t.kind == 'dir' then
      found = (files_in(s.entries, assert(t.path)))
    end
    for _, e in ipairs(found) do
      if not seen[e.path] then
        seen[e.path] = true
        entries[#entries + 1] = e
      end
    end
  end
  if #entries == 0 then
    return false
  end
  if wait_for_read(s) then
    return true
  end
  local action, why
  if op == 'stage' then
    action, why = stage.stage_all(entries, 'the selection')
  else
    action, why = stage.unstage_all(entries, s.has_head, 'the selection')
  end
  if not action then
    util.info(why or 'nothing to do')
    return true
  end
  local err = stage.run(action, s.root)
  if err then
    util.git_error(err)
    return true
  end
  s.outdated = true
  M.refresh(s)
  return true
end

--- Say why the rows of an unmerged file cannot be staged or unstaged, if
--- `entry` is one.
---
--- Its view shows the working tree, conflict markers and all, and there is no
--- stage 0 in the index to write rows into: writing one over the merge stages
--- discards them, and git reports no error. Checked ahead of finding the rows:
--- the view has no index contents to write them into, and its rows are no
--- changes, so either would end the press without a word.
--- @param entry gitview.StatusEntry
--- @return boolean refused
local function refuses_conflict(entry)
  if not entry.conflicted then
    return false
  end
  local why = '%s has an unresolved conflict; edit the file, or stage it whole to mark it resolved'
  util.warn(why:format(entry.path))
  return true
end

--- Say why nothing in the diff can be moved the way `op` asks, if the layer
--- shown is the one it would move rows into: unstaged alone has nothing staged
--- to unstage, and staged alone nothing to stage.
--- @param s gitview.Session
--- @param op 'stage'|'unstage'
--- @return boolean refused
local function refuses_layer(s, op)
  local shown = op == 'stage' and 'staged' or 'unstaged'
  if s.layer ~= shown then
    return false
  end
  util.info(('only %s changes are shown'):format(shown))
  return true
end

--- Move some of the selected file's rows across the index, then redraw.
---
--- The rows on display are the operation's whole input: each one says which
--- layer it belongs to and where it sits in the index, so a range of rows is
--- enough to state what to write. Which rows those are — one, a visual
--- selection, a hunk — is the caller's business.
---
--- @param s gitview.Session
--- @param op 'stage'|'unstage'
--- @param first integer 1-based row of the diff buffer
--- @param last integer inclusive
--- @return boolean handled false when the diff shows nothing to stage
function M.apply_to_rows(s, op, first, last)
  local target = s.selected
  if refuses_review(target) then
    return true
  end
  -- The rows of a file would do here, as they do in its own diff, but the index
  -- contents to write them into are read for one file. Of the views of many
  -- files, only a directory's sits among the files that can be staged by row.
  if target and target.kind == 'dir' then
    util.info("lines can be staged only in a single file's diff; the directory's row in the list takes all of its files")
    return true
  end
  if wait_for_read(s) then
    return true
  end
  local entry = target and target.kind == 'file' and s.entries[target.index] or nil
  if entry and refuses_conflict(entry) then
    return true
  end
  local view = render.view_of(s.diff_buf)
  if not entry or not view or not s.index_lines then
    return false
  end
  if refuses_layer(s, op) then
    return true
  end
  -- Ignoring whitespace folds a line that differs only in whitespace into a
  -- context row, whose text is read from the index. Writing the shown rows back
  -- would then leave that line at its index version while the working tree kept
  -- the other, and the view — still ignoring whitespace — would go on showing
  -- nothing unstaged. Whole-file `s` is unaffected: it is `git add`, and reads no
  -- rows.
  if s.ignore_whitespace then
    util.warn('whitespace is being ignored; stage the whole file, or stop ignoring it')
    return true
  end
  local rows = index.selection(view.lines, first, last, op)
  if #rows == 0 then
    util.info(('nothing to %s here'):format(op))
    return true
  end
  local err = index.write(op, entry, index.apply(s.index_lines, rows), s.root)
  if err then
    util.git_error(err)
    return true
  end
  -- With one layer alone, what was moved leaves the view, and the change it
  -- was part of with it when it was all of it. The cursor goes on from where
  -- the change began.
  if view.layer then
    local at = first
    while at <= last and not index.selection(view.lines, at, at, op)[1] do
      at = at + 1
    end
    place_next(s, place.after_change, index.hunk_at(view.lines, at) or at)
  end
  s.outdated = true
  M.refresh(s)
  return true
end

--- Move the whole change the diff's cursor is in across the index.
--- @param s gitview.Session
--- @param op 'stage'|'unstage'
--- @return boolean handled false when the diff shows nothing to stage
function M.apply_to_hunk(s, op)
  local target = s.selected
  if refuses_review(target) then
    return true
  end
  local entry = target and target.kind == 'file' and s.entries[target.index]
  if entry and (refuses_conflict(entry) or refuses_layer(s, op)) then
    return true
  end
  local view = render.view_of(s.diff_buf)
  local first, last = index.hunk_at(view and view.lines or {}, vim.fn.line('.'))
  if not first then
    util.info('not inside a change')
    return true
  end
  return M.apply_to_rows(s, op, first, last)
end

--- The files a row of the review stands for: its file, or those under its
--- directory.
--- @param r gitview.Review
--- @param t gitview.ListTarget?
--- @return string[]
local function review_paths_at(r, t)
  if not (t and t.review) then
    return {}
  end
  if t.kind == 'commit_dir' then
    return vim.tbl_map(function(c)
      return c.path
    end, (files_in(r.scope.changes, assert(t.path))))
  end
  local c = r.scope.changes[t.index]
  return c and { c.path } or {}
end

--- Say why `paths` cannot be checked off, if one of them is unmerged and the
--- toggle would check them rather than take their checks off.
---
--- An unmerged file is not yet what it will be: what is read of it is its
--- conflict markers, and resolving it is still to come. Taking a check off is
--- always allowed. The paths go one way together, so a conflict among them
--- refuses the rest too.
--- @param r gitview.Review
--- @param paths string[]
--- @return boolean refused
local function refuses_check(r, paths)
  if not review.would_check(r.checks, paths) then
    return false
  end
  local wanted = {}
  for _, path in ipairs(paths) do
    wanted[path] = true
  end
  for _, c in ipairs(r.scope.changes) do
    if c.status == 'U' and wanted[c.path] then
      util.warn(('%s has an unresolved conflict; resolve it before checking it off'):format(c.path))
      return true
    end
  end
  return false
end

--- Check off the files under the rows of the files pane from `first` to
--- `last`, or take their checks off when every one is checked already.
--- @param s gitview.Session
--- @param first integer 1-based
--- @param last integer inclusive
--- @return boolean handled false when the rows stand for no file
function M.check_rows(s, first, last)
  local r = s.review
  if not r then
    util.info('files are checked off during a review')
    return true
  end
  local paths, seen = {}, {}
  for row = first, last do
    for _, path in ipairs(review_paths_at(r, list.target_at(s.files_buf, row))) do
      if not seen[path] then
        seen[path] = true
        paths[#paths + 1] = path
      end
    end
  end
  if #paths == 0 then
    return false
  end
  if refuses_check(r, paths) then
    return true
  end
  -- Read each file as it is now, as a row has no view on screen to go by.
  -- `toggle` records what was read only when it checks the files off.
  local reads = {}
  for _, path in ipairs(paths) do
    reads[path] = read_as(s, r, path)
  end
  review.toggle(r.checks, paths, reads)
  redraw_checks(s)
  return true
end

--- The files the diff shows under review, in order, and which of them `row`
--- is in, or why there are none.
--- @param s gitview.Session
--- @param row integer 1-based, of the diff
--- @return string[]? paths
--- @return integer|string at the index of the row's file into `paths`, 0
---        above the first; or why there is nothing
--- @return boolean? many whether the files are those of one view
local function shown_review_files(s, row)
  local r, t = s.review, s.selected
  if not (r and t and t.review) then
    return nil, r and 'not a file under review' or 'files are checked off during a review'
  end
  if t.kind == 'commit_file' then
    return review_paths(r), t.index, false
  end
  local view = render.view_of(s.diff_buf)
  if not view or not (s.drawn and s.drawn.view == view) then
    return nil, 'no file here'
  end
  local at = 0
  for i, f in ipairs(view.files) do
    if f.row <= row then
      at = i
    end
  end
  return view_paths(s, view), at, true
end

--- Go on to the next file still to be read in `dir`, from the file at `at`.
---
--- Files of one view are gone through by scrolling to the next one's header.
--- A file on its own is one of the files pane's, and the cursor goes on there,
--- as `]f` moves it.
--- @param s gitview.Session
--- @param paths string[]
--- @param at integer
--- @param many boolean
--- @param dir 1|-1
local function go_to_open(s, paths, at, many, dir)
  local r = assert(s.review)
  -- Go back from above the first file as from after the last: counting back
  -- from 0 would come to the last one only after all the others.
  local from = (at == 0 and dir < 0) and #paths + 1 or at
  local to = review.next_open(r.checks, paths, from, dir)
  if not to then
    util.info('every file is checked')
    return
  end
  if many then
    local view = assert(render.view_of(s.diff_buf))
    vim.api.nvim_win_set_cursor(s.diff_win, { view.files[to].row, 0 })
    return
  end
  select_nth(s, assert(s.selected), to)
end

--- Check off the files the rows `first` to `last` of the diff are in, or take
--- their checks off when every one is checked already, and on checking go on to
--- the next one to read: read, check, next is how a review goes. Taking a check
--- off stays, since the file is the one to read again.
---
--- A diff of one file is that file whichever of its rows are given.
--- @param s gitview.Session
--- @param first integer 1-based
--- @param last integer inclusive
function M.check_shown(s, first, last)
  local paths, at, many = shown_review_files(s, first)
  if not paths then
    util.info(tostring(at))
    return
  end
  --- @cast at integer
  local to = at
  if many then
    to = select(2, shown_review_files(s, last)) --[[@as integer]]
  end
  -- Record the lines the view was built from rather than the file now, which
  -- may have moved on without anything having drawn it again. A file shown
  -- with no view, such as a binary one, has nothing on screen to go by but its
  -- name.
  local r = assert(s.review)
  local view = render.view_of(s.diff_buf)
  local picked, reads = {}, {}
  for i = math.max(at, 1), to do
    local path = paths[i]
    if path then
      local drawn = view and s.drawn and s.drawn.view == view and view.files[many and i or 1]
      local lines = drawn and (vim.fs.relpath(s.root, drawn.path) == path) and drawn.new_lines or nil
      picked[#picked + 1] = path
      reads[path] = read_as(s, r, path, lines)
    end
  end
  if #picked == 0 then
    util.info('no file here')
    return
  end
  if refuses_check(r, picked) then
    return
  end
  local checked = review.toggle(r.checks, picked, reads)
  redraw_checks(s)
  if checked then
    go_to_open(s, paths, to, many == true, 1)
  end
end

--- Close the session, asking first if that throws a review away part way
--- through; see `may_discard`. Only `q` asks: closing the tab page some other
--- way cannot be stopped, since the session is let go of once it is gone, and
--- `q` is the one pressed by accident.
--- @param s gitview.Session
function M.close_asked(s)
  if may_discard(s) then
    M.close(s)
  end
end

--- Go on to the next file still to be read in `dir`, from the file the diff's
--- cursor is in; see `go_to_open`.
--- @param s gitview.Session
--- @param dir 1|-1
function M.step_open(s, dir)
  local paths, at, many = shown_review_files(s, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  if not paths then
    util.info(tostring(at))
    return
  end
  --- @cast at integer
  go_to_open(s, paths, at, many == true, dir)
end

--- Go on to the next file still to be read in `dir`, from the row the files
--- pane's cursor is on; see `go_to_open`. A directory's row stands just before
--- its first file.
--- @param s gitview.Session
--- @param win integer the files pane, or a window split off from it
--- @param dir 1|-1
function M.step_listed_open(s, win, dir)
  local r = s.review
  if not r then
    util.info('files are checked off during a review')
    return
  end
  local paths = review_paths(r)
  local t = list.target_at(s.files_buf, vim.api.nvim_win_get_cursor(win)[1])
  local from = dir > 0 and 0 or #paths + 1
  if t and t.review and t.kind == 'commit_file' then
    from = t.index
  elseif t and t.review and t.kind == 'commit_dir' then
    local _, indices = files_in(r.scope.changes, assert(t.path))
    if indices[1] then
      from = dir > 0 and indices[1] - 1 or indices[1]
    end
  end
  local to = review.next_open(r.checks, paths, from, dir)
  if not to then
    util.info('every file is checked')
    return
  end
  select_nth(s, { kind = 'commit_file', index = to, review = true }, to)
end

--- Move a list's cursor to the next row of a file in `dir`, passing over the
--- rows of directories, and show it. The focus stays in the list.
--- @param s gitview.Session
--- @param win integer a list pane, or a window split off from one
--- @param dir 1|-1
--- @return boolean moved false when no file's row is that way, as in the
---         commits pane while no commit is being looked into
function M.step_listed_file(s, win, dir)
  local buf = vim.api.nvim_win_get_buf(win)
  local count = vim.api.nvim_buf_line_count(buf)
  local row = vim.api.nvim_win_get_cursor(win)[1] + dir
  while row >= 1 and row <= count do
    local t = list.target_at(buf, row)
    if t and (t.kind == 'file' or t.kind == 'commit_file') then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      M.follow_cursor(s, win)
      return true
    end
    row = row + dir
  end
  return false
end

--- Move to the next file in `dir` from the one the diff shows.
---
--- A commit's or a directory's diff is many files in one buffer, so moving
--- between files there means scrolling within it rather than moving the list's
--- cursor. Every other view holds one file, and the list's cursor moves on,
--- the focus staying in the diff: the key was pressed while reading it, and the
--- next file is read there too.
--- @param s gitview.Session
--- @param dir 1|-1
--- @return boolean moved false when there is no file that way
function M.step_file(s, dir)
  local t = s.selected
  if shows_many(t) then
    return keymap.jump_files(dir)
  end
  local like = (t and t.kind == 'commit_file') and t or { kind = 'file', index = 1 }
  return select_nth(s, like, (t and t.index or 1) + dir)
end

--- Open the file the diff's cursor is in, at the line it stands on, with the
--- cursor on the same column and screen row as in the diff; see `open_file`.
---
--- A diff row's text is its line's text as is, the signs being drawn in the
--- gutter, so a column of the row is the same column of the line.
--- @param s gitview.Session
function M.open_shown(s)
  local view = render.view_of(s.diff_buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local path, lnum = nil, nil
  if view then
    path, lnum = keymap.source_at(view, cursor[1])
  end
  if not path then
    util.info('no file here')
    return
  end
  local l = assert(view).lines[cursor[1]]
  M.open_file(s, path, assert(lnum), {
    winline = vim.fn.winline(),
    col = cursor[2],
    -- A file's header and the blank row after it are not lines of the file.
    text = l and dlib.source_kinds[l.kind] and l.text or nil,
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
    group = vim.api.nvim_create_augroup('gitview.ui.session', { clear = true }),
    desc = 'gitview: re-read the status tab page',
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
--- @param s gitview.Session
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
--- @param s gitview.Session
local function unwatch_index(s)
  if s.watcher then
    s.watcher:stop()
    s.watcher:close()
    s.watcher = nil
  end
end

--- The name of the augroup holding one session's own autocommands.
--- @param s gitview.Session
local function augroup_name(s)
  return 'gitview.ui.session.' .. s.tab
end

--- Drop everything the session holds: its registration, its watcher, its
--- autocommands and its buffers. Deleting the buffers closes whatever windows
--- still show them, except a window that is the last one there is, which is
--- handed another buffer instead.
--- @param s gitview.Session
local function teardown(s)
  M.sessions[s.tab] = nil
  unwatch_index(s)
  unwatch_upstream(s)
  unwatch_config(s)
  pcall(vim.api.nvim_del_augroup_by_name, augroup_name(s))
  for _, win in ipairs({ s.files_win, s.commits_win, s.diff_win }) do
    -- A window that survives is no longer a pane, so it must not stay pinned
    -- to whatever buffer it is handed.
    if vim.api.nvim_win_is_valid(win) then
      util.configure_window_options(win, { winfixbuf = false })
    end
  end
  for _, buf in ipairs({ s.files_buf, s.commits_buf, s.diff_buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

--- Name the session's buffers, which is what the tab page's label shows in place
--- of `[Scratch]`. The label follows the current window, so the files pane,
--- which a session opens in, carries the plain name. Buffer names must be unique,
--- so a session on another repository opened while one is still around takes a
--- numbered set, the same number for all three buffers.
---
--- The names are URIs. A plain name is a path relative to the current directory,
--- and where a directory goes by it (case aside, on macOS) netrw takes the pane
--- over as a listing of that directory. The label shortens what comes before the
--- last `/`, so it reads `g//Gitview`.
--- @param s gitview.Session
local function name_buffers(s)
  local names = { 'gitview://Gitview', 'gitview://Gitview:commits', 'gitview://Gitview:diff' }
  local suffix, n = '', 1
  while
    vim.iter(names):any(function(name)
      return vim.fn.bufexists(name .. suffix) == 1
    end)
  do
    n = n + 1
    suffix = ' (' .. n .. ')'
  end
  for i, buf in ipairs({ s.files_buf, s.commits_buf, s.diff_buf }) do
    vim.api.nvim_buf_set_name(buf, names[i] .. suffix)
  end
end

--- The fewest columns the sidebar takes, however narrow the screen.
local MIN_LIST_WIDTH = 30
--- The fewest rows the commits pane takes, however short the screen.
local MIN_COMMITS_HEIGHT = 3

--- Size the sidebar to its shares of the screen: its width out of the columns,
--- and the commits pane's height out of the sidebar's. The diff takes whatever
--- width is left, and the files pane whatever height.
--- @param s gitview.Session
local function lay_out(s)
  local width = math.floor(vim.o.columns * config.values.sidebar_width_ratio)
  vim.api.nvim_win_set_width(s.files_win, math.max(MIN_LIST_WIDTH, width))
  local total = vim.api.nvim_win_get_height(s.files_win)
    + vim.api.nvim_win_get_height(s.commits_win)
  local height = math.floor(total * config.values.commits_height_ratio)
  vim.api.nvim_win_set_height(s.commits_win, math.max(MIN_COMMITS_HEIGHT, height))
end

--- Open a tab page listing everything uncommitted, or go to the one already
--- open for the repository. A second tab page on the same repository would show
--- nothing the first does not. Going back to it leaves its origin alone: `gf`
--- keeps opening files where the session was first opened from.
--- @return gitview.Session?
function M.open()
  local root = source.repo_root()
  if not root then
    return
  end
  for _, s in pairs(M.sessions) do
    if s.root == root then
      vim.api.nvim_set_current_tabpage(s.tab)
      return s
    end
  end
  set_hooks()
  local origin = vim.api.nvim_get_current_tabpage()
  vim.cmd.tabnew()
  local s = { --- @type gitview.Session
    tab = vim.api.nvim_get_current_tabpage(),
    root = root,
    origin = origin,
    files_win = vim.api.nvim_get_current_win(),
    files_buf = list.create_buffer(),
    commits_buf = list.create_buffer(),
    diff_buf = render.create_buffer(),
    uncommitted = {},
    entries = {},
    files_notice = list.LOADING_NOTICE,
    reads = 0,
    commits = {},
    generation = 0,
    details = {},
    auto_merges = {},
    range_reads = {},
    range_order = {},
    positions = {},
    focused = {},
    listing = 'log',
    ignore_whitespace = config.values.ignore_whitespace,
    layer = config.values.shown_changes,
    has_head = git.has_head(root),
  }
  s.commits = read_commits(s)
  reread_upstream(s)
  name_buffers(s)
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

  -- The order is what lets a user's configuration of a pane win where it can
  -- and not where it cannot. The filetype comes once the panes are in their
  -- windows, so that `FileType` runs in each pane's window and an ftplugin
  -- setting window options sets them there. It comes after the default keys,
  -- so that a user mapping the same key from there replaces them, and after
  -- the options a user may change, so that a value set there is kept. The
  -- options the panes are drawn with come last, over any set there.
  keymaps.set(s)
  list.set_window_defaults(s.files_win)
  list.set_window_defaults(s.commits_win)
  render.set_window_defaults(s.diff_win)
  vim.bo[s.files_buf].filetype = 'gitview-files'
  vim.bo[s.commits_buf].filetype = 'gitview-commits'
  vim.bo[s.diff_buf].filetype = 'gitview-diff'
  list.fix_window(s.files_win)
  list.fix_window(s.commits_win)
  render.fix_window(s.diff_win)
  util.configure_window_options(s.commits_win, {
    -- Turned off while a range is shown, which is painted instead.
    cursorline = true,
    -- Pinned so that a window opened or closed in the sidebar leaves the
    -- commits pane as it is; a resize of the screen sets it again by its share.
    winfixheight = true,
  })
  -- Each pane is only ever drawn with its own buffer, so `:edit` or `:bnext`
  -- there is refused rather than leaving a pane the session goes on drawing
  -- into blind. A window split off from a pane does not inherit it, which
  -- leaves `:split` as the way to open something else here.
  for _, win in ipairs({ s.files_win, s.commits_win, s.diff_win }) do
    util.configure_window_options(win, { winfixbuf = true })
  end
  lay_out(s)

  for _, buf in ipairs({ s.files_buf, s.commits_buf }) do
    vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinEnter' }, {
      buffer = buf,
      callback = function()
        -- A pane closed with the cursor in it hands the cursor to another,
        -- with the session missing a pane it would draw into.
        if s.closing then
          return
        end
        -- `WinEnter` as well as `CursorMoved`: moving between the two panes does
        -- not move either cursor, so nothing else would tell the diff that the
        -- selection is now the other pane's.
        M.follow_cursor(s, vim.api.nvim_get_current_win())
      end,
    })
  end

  vim.api.nvim_create_autocmd({ 'WinEnter', 'WinLeave' }, {
    buffer = s.diff_buf,
    callback = function()
      if s.closing then
        return
      end
      -- `WinLeave` as well, for what was moved to from inside the diff, as
      -- `]f` and `]r` do.
      M.note_focused(s)
    end,
  })

  M.sessions[s.tab] = s
  watch_index(s)
  watch_config(s)
  local group = vim.api.nvim_create_augroup(augroup_name(s), { clear = true })
  vim.api.nvim_create_autocmd('TabClosed', {
    group = group,
    -- Deleting the buffers has to fire their BufWipeout, which is what forgets
    -- the state kept by buffer: a view kept past its buffer would have a step
    -- filling in its syntax write to a buffer that is gone.
    nested = true,
    callback = function()
      -- TabClosed does not say which tab went, so this checks its own.
      if not vim.api.nvim_tabpage_is_valid(s.tab) then
        teardown(s)
      end
    end,
  })
  -- Shares rather than sizes, so the sidebar keeps its proportions as the
  -- screen grows or shrinks. A session in another tab page waits until it is
  -- entered again, and only then if the screen did change: laying it out on
  -- every return would undo a width set by hand.
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if vim.api.nvim_get_current_tabpage() == s.tab then
        lay_out(s)
      else
        s.resized = true
      end
    end,
  })
  vim.api.nvim_create_autocmd('TabEnter', {
    group = group,
    callback = function()
      if s.resized and vim.api.nvim_get_current_tabpage() == s.tab then
        s.resized = nil
        lay_out(s)
      end
    end,
  })
  -- A session missing a pane has nowhere to draw what that pane showed, and
  -- putting the layout back would fight whoever just took it apart. Closing a
  -- pane closes the session instead, the same as `q` does, which also covers a
  -- pane moved off with `CTRL-W T`: that closes the window and opens another.
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = { tostring(s.files_win), tostring(s.commits_win), tostring(s.diff_win) },
    callback = function()
      -- Marked at once rather than with the close: the pane is gone before the
      -- scheduled close runs, and another is entered in between.
      s.closing = true
      -- Windows cannot be closed from inside WinClosed. Closing the tab page
      -- closes every pane, and each lands here, so all but the first find the
      -- session already gone.
      vim.schedule(function()
        if M.sessions[s.tab] ~= s then
          return
        end
        -- `M.close` would `:quit` a sole tab page, and closing one pane is not
        -- asking for Neovim to exit.
        if #vim.api.nvim_list_tabpages() > 1 then
          M.close(s)
        else
          teardown(s)
        end
      end)
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
