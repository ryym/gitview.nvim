--- One tab page showing a repository's uncommitted changes: the file list on
--- the left, the selected file's diff on the right.
---
--- A session outlives the moment it was opened in. It keeps enough state to be
--- redrawn when the repository changes underneath it — which it does by itself
--- on entering its tab page — and to follow the cursor from one file to the next.
local config = require('gitview.config')
local git = require('gitview.git')
local index = require('gitview.index')
local keymap = require('gitview.diff.keymap')
local list = require('gitview.ui.list')
local perf = require('gitview.perf')
local render = require('gitview.diff.render')
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
--- @field entries gitview.StatusEntry[] empty until the first read finishes
--- @field files_notice string? shown in place of the files while there are none
---        to show yet: until the first read finishes, or after it failed
--- @field reads integer bumped by every read of the status, so a read can tell
---        whether a later one has made it obsolete
--- @field reading boolean? whether a read of the status is under way
--- @field outdated boolean? whether the session has changed the index since the
---        panes were drawn. Staging from them then would write back the state
---        they show, undoing the change, so it waits for the read to catch up
--- @field commits gitview.Commit[] the tail of the history, newest first
--- @field ignore_whitespace boolean whether lines differing only in whitespace
---        count as changed; starts from the configuration and is toggled while
---        the session is open
--- @field mark string? sha of the marked commit, or `list.WORKTREE` for the
---        working-tree row. While it is set the commits pane compares it with
---        whatever the cursor is on, rather than showing one commit against its
---        parent
--- @field scope gitview.ListScope? the range being looked into, whose files
---        replace the commits pane while it is set
--- @field selected gitview.ListTarget? what the diff pane is showing
--- @field shown gitview.SelectionId? what it is currently showing, so that
---        redrawing the same thing can keep the scroll position
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
--- @field index_lines string[]? the selected file's index contents, for staging
---        part of it; nil whenever the pane shows a notice instead of a diff
--- @field details table<string, gitview.CommitDetail> commits' messages and
---        stats by sha: a commit never changes, but its stat is read again
---        when the diff pane is no longer the width it was laid out for
--- @field range_reads table<string, gitview.RangeRead> what the ranges between
---        two commits were last read as, by `range_key`, for `read_range`
--- @field range_order string[] the keys of `range_reads`, least recently used
---        first
--- @field empty_tree string? the empty tree's sha, once a range has needed it
--- @field resized boolean? whether the screen was resized while another tab
---        page was current, leaving the sidebar to be laid out on return

--- @type table<integer, gitview.Session>
M.sessions = {}

--- @return gitview.Session?
function M.current()
  return M.sessions[vim.api.nvim_get_current_tabpage()]
end

--- What the diff pane compares. Unlike the diff commands there is no choice of
--- revision here: the point of the view is what has not been committed.
local REV = 'HEAD, staged + unstaged'

--- @alias gitview.SelectionId {kind:'file'|'commit'|'worktree'|'commit_file'|'dir'|'commit_dir', id:string}

--- @param s gitview.Session
--- @return gitview.SelectionId?
local function selection_id(s)
  local t = s.selected
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
--- @param s gitview.Session
--- @return {algorithm:string, linematch:integer, ignore_whitespace:boolean}
local function diff_opts(s)
  local opts = config.diff_opts(config.values)
  opts.ignore_whitespace = s.ignore_whitespace
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
  if s.ignore_whitespace then
    notes[#notes + 1] = 'space ignored'
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

--- Which pane a kind of target lives in. The sidebar holds two lists, and a
--- selection belongs to exactly one of them.
--- @param s gitview.Session
--- @param kind 'file'|'commit'|'worktree'|'commit_file'|'dir'|'commit_dir'
--- @return integer win
--- @return integer buf
local function pane_of(s, kind)
  if kind == 'file' or kind == 'dir' then
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
--- @param s gitview.Session
local function reset_view(s)
  if vim.api.nvim_win_is_valid(s.diff_win) then
    vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
  end
end

--- The commit list, or nothing when there is no HEAD to read one from.
---
--- `git log` fails outright in a repository with no commit rather than printing
--- an empty log, so the question has to be asked before the command is run.
--- @param s gitview.Session
--- @return gitview.Commit[]
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
--- without a commit for it to be compared with.
--- @param s gitview.Session
--- @return boolean
local function has_worktree_row(s)
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
  for _, e in ipairs(s.entries) do
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
--- @return gitview.Range? range nil for the working tree on its own, which is
---         not a range but the uncommitted changes as the files pane has them
--- @return string label
local function range_of(s, target)
  local older, newer = ends_of(s, target)
  if not older then
    if target.kind == 'worktree' then
      return nil, REV
    end
    local commit = s.commits[target.index]
    return git.commit_range(commit), ('%s %s'):format(commit.sha, commit.subject)
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
    if commit and #commit.parents > 1 then
      return 'first parent'
    end
    return nil
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
--- @param commit gitview.Commit
--- @return gitview.CommitDetail?
local function kept_detail(s, commit)
  local detail = s.details[commit.sha]
  return detail and detail.stat_width == stat_width(s) and detail or nil
end

--- The message and stat of a commit, read on first use.
--- @param s gitview.Session
--- @param commit gitview.Commit
--- @return gitview.CommitDetail?
local function commit_detail(s, commit)
  if not kept_detail(s, commit) then
    local detail, err = git.commit_detail(commit, s.root, stat_width(s))
    if not detail then
      -- the diff under it is still worth showing
      util.git_error(assert(err))
      return nil
    end
    s.details[commit.sha] = detail
  end
  return s.details[commit.sha]
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
      render.notice(s.diff_buf, list.EMPTY_NOTICE)
    end
  end
  local sources, skipped = perf.measure('source', source.for_entries, entries, s.root)
  return function()
    local view, unchanged =
      perf.measure('build', vlib.build, sources, REV, config.values.context, diff_opts(s))
    view = vlib.list_skipped(view, REV, skipped, unchanged, no_view_reason(s))
    if not view then
      render.notice(s.diff_buf, ('%s   %s'):format(REV, no_view_reason(s)))
      return
    end
    view.note = note_of(s)
    render.draw(s.diff_buf, view)
  end
end

--- Whether the commits pane shows this commit on its own, against its first
--- parent, rather than as one end of a range.
--- @param commit gitview.Commit?
--- @param range gitview.Range?
--- @return boolean
local function is_whole_commit(commit, range)
  return commit ~= nil and range ~= nil and vim.deep_equal(range, git.commit_range(commit))
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
  local range, label = range_of(s, target)
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
  local detail = is_whole_commit(commit, range)
    and perf.measure('detail', commit_detail, s, assert(commit))

  return function()
    local view, unchanged =
      perf.measure('build', vlib.build, read.sources, label, config.values.context, diff_opts(s))
    view = vlib.list_skipped(view, label, read.skipped, unchanged, no_view_reason(s))
    if not view then
      render.notice(s.diff_buf, ('%s   %s'):format(label, no_view_reason(s)))
      return
    end
    view.note = note_of(s, note)
    if detail then
      vlib.prepend(view, vlib.commit_header(detail, assert(commit)))
    end
    render.draw(s.diff_buf, view)
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
    conflicted = vim.tbl_filter(under, read.skipped.conflicted),
  }
  return sources, skipped
end

--- Read a directory of the range being looked into. Returned as `read_entries`
--- returns it.
---
--- The whole range is read and kept, and the directory taken out of it: the
--- commit's own row and every other directory in it then share one read.
--- @param s gitview.Session
--- @param target gitview.ListTarget a directory of the scope
--- @return fun() draw
local function read_scope_dir(s, target)
  local scope = s.scope
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
    local view, unchanged =
      perf.measure('build', vlib.build, sources, scope.label, config.values.context, diff_opts(s))
    view = vlib.list_skipped(view, scope.label, skipped, unchanged, no_view_reason(s))
    if not view then
      render.notice(s.diff_buf, ('%s   %s'):format(scope.label, no_view_reason(s)))
      return
    end
    view.note = note_of(s)
    render.draw(s.diff_buf, view)
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
    local key = s.scope and range_key(s.scope.range)
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
  if is_whole_commit(commit, range) then
    return kept_detail(s, commit) ~= nil
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
    local label = target.kind == 'dir' and REV or (s.scope and s.scope.label or '')
    render.draw(s.diff_buf, vlib.placeholder(label, LOADING))
    return
  end
  local commit = target.kind == 'commit' and s.commits[target.index] or nil
  local range, label = range_of(s, target)
  local header
  if commit and is_whole_commit(commit, range) then
    local detail = s.details[commit.sha]
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

--- Draw one file of the range being looked into.
---
--- This is the same two-version view `show_many` draws, narrowed to one file:
--- one entry of the change list the scope already holds, so nothing has to be
--- listed again.
--- @param s gitview.Session
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

  local src = perf.measure('source', source.for_range_change, scope.range, change, s.root)
  local view = src
    and perf.measure('build', vlib.build, { src }, scope.label, config.values.context, diff_opts(s))
  if not view then
    -- a pure rename or a mode change: a real change with no lines to show
    render.notice(s.diff_buf, ('%s   %s'):format(label, no_view_reason(s)))
    return
  end
  view.note = note_of(s)
  render.draw(s.diff_buf, view)
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
    return s.scope ~= nil and s.scope.range.new == nil
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
  if shows_many(target) then
    show_many(s, target, span)
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

  local src = perf.measure('source', source.for_entry, entry, s.root)
  local view = src
    and perf.measure('build', vlib.build, { src }, REV, config.values.context, diff_opts(s))
  if not view then
    -- a pure rename or a mode change: a real change with no lines to show
    render.notice(s.diff_buf, ('%s   %s'):format(status.label(entry), no_view_reason(s)))
    return
  end
  view.note = note_of(s)
  render.draw(s.diff_buf, view)
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
--- @param win integer the pane whose cursor decides the selection
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
--- Which list that is depends on where the session is: the uncommitted changes,
--- or the files of the commit being looked into.
--- @param s gitview.Session
--- @param kind 'file'|'commit_file'
--- @param index integer
local function select_nth(s, kind, index)
  local count = kind == 'file' and #s.entries or #(s.scope and s.scope.changes or {})
  if count == 0 then
    return
  end
  index = math.max(1, math.min(count, index))
  local target = { kind = kind, index = index } --- @type gitview.ListTarget
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
--- @param s gitview.Session
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
--- @param s gitview.Session
--- @param id gitview.SelectionId?
--- @return gitview.ListTarget?
local function target_of_id(s, id)
  if not id then
    return nil
  end
  if id.kind == 'worktree' then
    return has_worktree_row(s) and { kind = 'worktree', index = 1 } or nil
  end
  -- A directory is still there as long as a file in it is.
  if id.kind == 'dir' or id.kind == 'commit_dir' then
    local files = id.kind == 'dir' and s.entries or (s.scope and s.scope.changes or {})
    local _, indices = files_in(files, id.id)
    return indices[1] and { kind = id.kind, index = indices[1], path = id.id } or nil
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
--- @param s gitview.Session
--- @param target gitview.ListTarget? where the cursor should end up
--- @param keep_unchanged boolean? passed on to `show_selected`
local function redraw_list(s, target, keep_unchanged)
  local as_tree = config.values.list_style == 'tree'
  list.draw(s.files_buf, {
    pane = 'files',
    root = s.root,
    entries = s.entries,
    notice = s.files_notice,
    tree = as_tree,
  })
  list.draw(s.commits_buf, {
    pane = 'commits',
    root = s.root,
    commits = s.commits,
    worktree = has_worktree_row(s),
    scope = s.scope,
    stale = s.commits_stale,
    tree = as_tree,
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
--- @param s gitview.Session
--- @param id gitview.SelectionId? what is selected, named before the re-read
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
  drop_lost_mark(s)
end

--- List again what a range ending at the working tree changed, since the working
--- tree may have moved on. A range between commits cannot have, and is left as
--- it is; so is the list when it cannot be read, being the best there is.
--- @param s gitview.Session
local function reread_scope(s)
  local scope = assert(s.scope)
  if scope.range.new then
    return
  end
  local changes = git.changed_between(scope.range, s.root, untracked_paths(s))
  if changes then
    scope.changes = changes
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
--- @param s gitview.Session
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
    -- The first list read puts the cursor on the first file rather than the
    -- first row, which in a tree is the root and shows nothing.
    local first = s.files_notice ~= nil and #s.entries == 0
    s.entries = entries
    s.files_notice = nil
    s.outdated = nil
    -- While a range is being looked into, the commits pane shows its files and
    -- the log behind them is off screen, so re-reading it would buy nothing.
    -- Backing out is what reads it again.
    if not s.scope then
      read_log(s, id)
    else
      reread_scope(s)
    end
    -- The working-tree row comes and goes with the entries, and its mark with it.
    drop_lost_mark(s)
    local target = target_of_id(s, id)
    if not target and first and #entries > 0 then
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
--- @param s gitview.Session
function M.toggle_whitespace(s)
  s.ignore_whitespace = not s.ignore_whitespace
  s.generation = s.generation + 1
  M.show_selected(s)
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
function M.set_mark(s)
  local target, mark = selected_end(s)
  if not target then
    return
  end
  s.mark = mark
  redraw_list(s, target)
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
function M.enter(s)
  local target, at = selected_end(s)
  if not target then
    return
  end
  local range, label = range_of(s, target)
  if not range then
    vim.api.nvim_set_current_win(s.files_win)
    return
  end
  local changes, err = git.changed_between(range, s.root, untracked_paths(s))
  if not changes then
    util.git_error({ what = 'git diff ' .. label, stderr = err or '' })
    return
  end
  s.scope = { range = range, label = label, at = assert(at), changes = changes }
  redraw_list(s, { kind = 'commit_file', index = 1 })
end

--- Go back to the uncommitted changes, with the cursor on the commit that was
--- being looked into.
--- @param s gitview.Session
function M.leave(s)
  local scope = s.scope
  if not scope then
    return
  end
  s.scope = nil
  local kind = scope.at == list.WORKTREE and 'worktree' or 'commit'
  local id = { kind = kind, id = scope.at } --- @type gitview.SelectionId
  -- The log went unread while the range's files stood in front of it, and it may
  -- have moved on since. Reading it here is also what decides whether the commit
  -- being backed out onto is still in it.
  read_log(s, id)
  redraw_list(s, target_of_id(s, id))
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
function M.open_file(s, path, lnum)
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
  local ok, err = pcall(keymap.edit_at, path, lnum)
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
local function open_listed(s, win)
  local buf = vim.api.nvim_win_get_buf(win)
  local target = list.target_at(buf, vim.api.nvim_win_get_cursor(win)[1])
  local item
  if target and target.kind == 'file' then
    item = s.entries[target.index]
  elseif target and target.kind == 'commit_file' then
    item = s.scope and s.scope.changes[target.index]
  end
  if target and target.kind == 'worktree' then
    util.info('the uncommitted changes are many files; open one from the files pane')
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

--- Refuse to stage from panes the session has made out of date, saying why.
--- @param s gitview.Session
--- @return boolean refused
local function wait_for_read(s)
  if not s.outdated then
    return false
  end
  util.info('the status is being re-read; try again in a moment, or refresh with R')
  return true
end

--- Change the index for the file or directory under the cursor, then redraw.
---
--- Both panes are rebuilt from git rather than adjusted in place: the status
--- letters, the file's three versions and which lines count as staged all move
--- together, and re-reading is what keeps them agreeing.
---
--- The cursor is left on the row it was on. Staging or unstaging never removes a
--- file from the list — it still differs from HEAD either way — and the list is
--- ordered by path, so the row goes on meaning the same file.
---
--- @param s gitview.Session
--- @param op 'stage'|'unstage'
local function apply_to_selected(s, op)
  local target = s.selected
  if not target or wait_for_read(s) then
    return
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
      return
    end
    if op == 'stage' then
      action, why = stage.stage(entry)
    else
      action, why = stage.unstage(entry, s.has_head)
    end
  else
    util.info('only an uncommitted file can be staged')
    return
  end
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
--- @param s gitview.Session
--- @param op 'stage'|'unstage'
--- @param first integer 1-based row of the diff buffer
--- @param last integer inclusive
local function apply_to_rows(s, op, first, last)
  local target = s.selected
  -- The rows of a file would do here, as they do in its own diff, but the index
  -- contents to write them into are read for one file. Of the views of many
  -- files, only a directory's sits among the files that can be staged by row.
  if target and target.kind == 'dir' then
    util.info("lines can be staged in a single file's diff; s and u on the directory row take all of its files")
    return
  end
  if wait_for_read(s) then
    return
  end
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
--- @param s gitview.Session
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
--- @param s gitview.Session
--- @param buf integer
local function set_shared_keymaps(s, buf)
  local map = util.buf_mapper(buf)
  map('R', function()
    M.refresh(s)
  end, 'refresh')
  map('q', function()
    M.close(s)
  end, 'close')
  map('gf', function()
    open_listed(s, vim.api.nvim_get_current_win())
  end, 'open the file under the cursor in the previous tab page')
end

--- What the keys do in the files pane.
--- @param s gitview.Session
local function set_files_keymaps(s)
  local map = util.buf_mapper(s.files_buf)
  map('<CR>', function()
    vim.api.nvim_set_current_win(s.diff_win)
  end, 'focus the diff')
  -- `s` and `u` rather than one key toggling: a file with changes on both sides
  -- has no obvious sense in which it is on or off, and a row here states that
  -- state rather than hiding it, so the direction is given explicitly.
  map('s', function()
    apply_to_selected(s, 'stage')
  end, 'stage the file or directory under the cursor')
  map('u', function()
    apply_to_selected(s, 'unstage')
  end, 'unstage the file or directory under the cursor')
  set_shared_keymaps(s, s.files_buf)
end

--- What the keys do in the commits pane.
---
--- Separating the panes is what lets each one carry only the keys that mean
--- something in it. `s` and `u` are the exception: they are mapped in order to
--- say why they do nothing, since leaving them unmapped would let `s` reach a
--- buffer that cannot be modified and error.
---
--- @param s gitview.Session
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
    M.set_mark(s)
  end, 'mark this commit as the far end of a range')
  map('<Esc>', function()
    -- `<Esc>` is commonly mapped already, to `:nohlsearch` above all, and this
    -- map hides it in the pane: with no range to clear it does what it would
    -- have done.
    if not M.clear_mark(s) then
      util.run_global_map('n', '<Esc>')
    end
  end, 'clear the range')
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
--- @param s gitview.Session
local function set_whitespace_keymap(s)
  for _, buf in ipairs({ s.files_buf, s.commits_buf, s.diff_buf }) do
    util.buf_mapper(buf)('gw', function()
      M.toggle_whitespace(s)
    end, 'toggle ignoring whitespace')
  end
end

--- @param s gitview.Session
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
      if t and (t.kind == 'commit' or t.kind == 'worktree') then
        keymap.jump_files(dir)
        return
      end
      -- The focus stays in the diff: the key was pressed while reading it, and
      -- the next file is read there too.
      local in_scope = t and (t.kind == 'commit_file' or t.kind == 'commit_dir')
      local kind = in_scope and 'commit_file' or 'file'
      -- A directory's index is the next file below it, which `]f` goes to
      -- rather than past.
      local is_dir = t and (t.kind == 'dir' or t.kind == 'commit_dir')
      local step = (is_dir and dir > 0) and 0 or dir
      select_nth(s, kind, (t and t.index or 1) + step)
    end,
    open_file = function(path, lnum)
      M.open_file(s, path, lnum)
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
--- @param s gitview.Session
local function name_buffers(s)
  local names = { 'GitView', 'GitView:commits', 'GitView:diff' }
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
  local width = math.floor(vim.o.columns * config.values.list_ratio)
  vim.api.nvim_win_set_width(s.files_win, math.max(MIN_LIST_WIDTH, width))
  local total = vim.api.nvim_win_get_height(s.files_win)
    + vim.api.nvim_win_get_height(s.commits_win)
  local height = math.floor(total * config.values.commit_ratio)
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
    entries = {},
    files_notice = list.LOADING_NOTICE,
    reads = 0,
    commits = {},
    generation = 0,
    details = {},
    range_reads = {},
    range_order = {},
    ignore_whitespace = config.values.ignore_whitespace,
    has_head = git.has_head(root),
  }
  s.commits = read_commits(s)
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

  list.configure_window(s.files_win)
  list.configure_window(s.commits_win)
  render.configure_window(s.diff_win, s.diff_buf)
  -- Each pane is only ever drawn with its own buffer, so `:edit` or `:bnext`
  -- there is refused rather than leaving a pane the session goes on drawing
  -- into blind. A window split off from a pane does not inherit it, which
  -- leaves `:split` as the way to open something else here.
  for _, win in ipairs({ s.files_win, s.commits_win, s.diff_win }) do
    util.configure_window_options(win, { winfixbuf = true })
  end
  -- Pinned so that a window opened or closed in the sidebar leaves the commits
  -- pane as it is; a resize of the screen sets it again by its share.
  vim.wo[s.commits_win].winfixheight = true
  lay_out(s)

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
