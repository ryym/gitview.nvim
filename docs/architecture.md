# Architecture

## Modules

The unified diff is one part of the plugin rather than the whole of it, so its
pipeline lives under `diff/` and the modules every part needs sit above it.

| module               | responsibility                                          |
| -------------------- | ------------------------------------------------------- |
| `init.lua`           | The `:GitView` command, and `setup()`                   |
| `config.lua`         | Defaults, and the subset `vim.diff` takes               |
| `git.lua`            | Every subprocess call, and the parsers for their output |
| `status.lua`         | What is uncommitted, as one entry per file               |
| `stage.lua`          | Which git command moves a file into or out of the index  |
| `index.lua`          | Writing part of a file's changes into the index          |
| `util.lua`           | Messages shown to the user                              |
| `perf.lua`           | Timings logged for development, off by default          |
| `diff/source.lua`    | Reading the versions to compare, and their filetype     |
| `diff/view.lua`      | Assembling sources into a view, and freeing it           |
| `diff/lines.lua`     | `vim.diff` wrapper, unified line list, del/add pairing  |
| `diff/mixed.lua`     | Merging HEAD, index and working tree into one line list |
| `diff/highlight.lua` | Scratch buffers, and collecting highlight segments      |
| `diff/worddiff.lua`  | Word-level ranges within a pair of changed lines        |
| `diff/render.lua`    | Building the buffer, extmarks, gutter, winbar           |
| `diff/keymap.lua`    | What the keys do inside a diff buffer                   |
| `ui/list.lua`        | A sidebar pane: its rows, its gutter, its winbar         |
| `ui/session.lua`     | One tab page's state, and redrawing it                   |

The dependency direction is one-way: `init` only opens a session, `source` uses
`status`, `stage` uses `status` and `git`, `index` uses `git`, `status` uses
`git`, `view` uses `lines`, `mixed` and `highlight`, `render` uses `highlight`,
`worddiff` and `lines`, `git` and `render` use `perf`, and `config`, `util`
and `perf` depend on nothing but Neovim.

`ui` uses `status` and, once it shows diffs, the pipeline under `diff/`; nothing
under `diff/` knows that `ui` exists.

`source` is the only part that reads git and the editor. It hands `view` plain
data, so assembling a view looks nothing up for itself.

## The status tab

`:GitView` opens a tab page that outlives the moment it was opened in. A
session keeps its repository root, its entries and the tail of the history, so
that all of them can be re-read — which is what lets it follow a repository that
moves on while it is open.

A session is registered against its tab page and dropped when that tab closes,
however it closes. Its three buffers go with it.

The list follows the same rule as a diff buffer: the text is the thing itself,
and everything around it is drawn. A row is a path, or a sha and a subject, and
nothing more, so yanking one gives something that names the thing elsewhere; the
status letters are painted by `'statuscolumn'`, and what the pane is holding by
`'winbar'`. Shortening works the same way in reverse: a sha is written whole and
its tail concealed by an extmark, so the row is still the thing itself when only
part of it is on screen.

A row stands for a `gitview.ListTarget` — a kind and an index — rather than for
an entry, because a row is no longer always a file: it can be a commit, the
working tree standing in the commit list, or a file of a range. A row can also stand for nothing, which is what the notices are. The
mapping is kept in both directions: the cursor picks a target, but `]f` picks a
file from inside the diff.

What a pane draws is a `gitview.ListModel` rather than a list of entries, and the
session hands each pane a fresh one on every redraw. The gutter is computed while
those rows are built rather than when the screen line is drawn: an entry has two
status letters, a commit's file has one and a commit has none, and putting that
decision in `'statuscolumn'` would mean teaching it every kind of row there is.
The one thing it decides is that a commits pane listing commits has no gutter
at all: none of its rows has anything to put there, and the width goes to the
subjects.

What follows the cursor is painted apart from the rows, in namespaces of its own,
since the cursor moves far more often than the list changes: the name of the
row the diff shows, and the rows of a range. A range is painted as a selection,
with the cursor line turned off meanwhile so their backgrounds do not run into
each other.

#### Two panes, not two sections

The sidebar is split: the uncommitted files above, the commits below, each its
own window and its own buffer. One buffer holding both would push the history off
the bottom of the screen as soon as a working tree had more changes than the
sidebar is tall — and the history is the part that does not grow.

Being separate windows is what makes the rest simple:

- **`list.state` is keyed by buffer**, so `'statuscolumn'` and `'winbar'` already
  read the pane they are drawn in. Telling the two apart needed nothing but a
  `pane` field for the winbar to switch on.
- **Each pane carries only the keys that mean something in it**, instead of one
  set of keys branching on the kind of row under the cursor. `s` and `u` are the
  exception: the commits pane maps them in order to say why they do nothing,
  since leaving `s` unmapped would let it reach a buffer that cannot be modified
  and error.
- **No row has to stand for nothing.** The section header and the blank row that
  separated the two lists are gone, and with them the rule that had to pull a
  cursor off them.

What two cursors cost is that neither moves when the focus does, so `WinEnter` is
watched alongside `CursorMoved`: entering a pane is the only thing that tells the
diff the selection now comes from that list.

The commits pane is the one with `'winfixheight'`. What the sidebar gains or
loses on a resize belongs to the files, which is the list that grows without
bound.

### The diff pane

The pane is one buffer for the life of the session, drawn into again on each
selection. Making a buffer per file and swapping it into the window would fire
the `Buf*` autocommands, disturb the alternate buffer and the jumplist, and
leave the old buffer to dispose of — on every cursor movement in the list.

What one buffer costs is that a position in it outlives the contents it belonged
to. Replacing the text only clamps the cursor to the new line count, so a short
diff drawn after a long one opens at its end. The pane is therefore put back to
its start whenever what it shows changes, and left alone whenever it does not:
staging a hunk redraws the same file, and being thrown back to the top on every
`s` would make working down a diff impossible.

Which of the two it is is decided by comparing what is shown — a kind and a path
or sha — rather than the selection itself, because a refresh can move a file to
another index while it goes on being the same file.

Each file is read as three versions and shown through `diff/mixed`, so the
choice between staged and unstaged never has to be made. Three things a view cannot express — a binary file, a change with no
lines, and nothing selected at all — are drawn by `render.notice`, which drops
the view along with the text so that the gutter and winbar describe nothing
rather than what was there before.

Three keys in the diff act on the session rather than on the buffer: `q` gives
up the whole session, `gf` opens the file as described below, and `]f` moves
the list's cursor — except in a commit's or the working tree's diff, which holds
every file and scrolls to the next one's header instead. `diff/keymap` takes
those as callbacks so that it does not depend on the session.

#### Opening a file

`gf` opens the file under the cursor from any pane: the file a list row names,
or the file a diff row belongs to, at the line of it the row stands for. It is
for a look at the whole file while reading its diff, so the session stays open.

- **It goes to the tab page the session was opened from**, into whichever window
  had the cursor there last. The session keeps that tab page as `origin`. Once it
  is closed, a new one is opened just before the session's and becomes `origin`
  in its place.
- **A window that cannot take the file is not replaced by another.** One pinned
  with `'winfixbuf'`, or holding unsaved changes under `'nohidden'`, makes `:edit`
  fail, and the error is reported. Picking some other window would make where the
  file lands hard to predict.
- **A row the new version lacks lands where it was.** A deleted line has no
  `new_lnum`, so it opens at the line after the nearest row above it that has
  one: the line that now stands in its place. A file's header and the blank row
  after its last line open it at the top. A commit's header belongs to no file.
- **A commit's line numbers are taken as they are.** They name lines of the file
  as the commit left it, which the working tree may have moved on from, and the
  line is clamped to the file as it is now. A file the working tree no longer
  has is refused rather than opened as a new, empty buffer.
- **A commit row opens nothing**: it stands for every file the commit touched.

### The commit list

The lower pane lists the most recent commits, and selecting one draws what it
changed. That view is the ordinary two-version one rather than a mixed view:
both sides are committed, so there is no index between them and nothing to mark
as staged.

Three things follow from both sides being committed:

- **Neither side comes from the working tree.** `source.for_range` reads both
  from the object database, in one `git cat-file --batch` as everything else
  does. The working tree is not one of the versions being compared, and may no
  longer have the file. The [working-tree row](#the-working-tree-row) is the one
  row that makes it a side, and then only the new one.
- **Its line numbers are the commit's.** `gf` still opens the file at the line
  a row names, which is close to where it now is rather than on it; see
  [Opening a file](#opening-a-file).
- **Nothing about it can be staged.** `s` and `u` refuse outright rather than
  relying on there being no index contents to write.

A commit the cursor lands on is read without blocking. Its diff is every file it
touched, and reading it in the foreground would stall the cursor on every row
passed over. Instead:

- A placeholder is drawn at once: the commit's subject and author as the log
  gave them, or its whole header when its message has been read before.
- The view is read in the background and replaces the placeholder once read.
- One view is read at a time. A row asked for meanwhile waits, replacing
  whatever was waiting, and a generation counter drops a result the selection
  has moved on from.
- What a range between two commits was read as is kept, for the last few dozen
  ranges, since neither end can change. A range ending at the working tree is
  read every time.
- A commit read before has nothing to wait for but its draw, which is still the
  costly part of a large one. It is drawn on the next turn of the event loop
  with no placeholder, so a row passed over before then is never drawn.

The working-tree row is read the same way. A file row costs a single file's
view and is drawn at once, as is anything drawn by a refresh.

#### The commit header

A commit shown on its own starts with what `git show --stat` prints before the
diff: subject, author and date, body, and stat. A range of two commits has no one
message and gets none, and neither does a file of a commit, whose commit the
pane's winbar already names. A mark on a commit's own parent is the same
comparison as the commit alone, and gets the header too.

- **It is buffer text**, for the same reasons as the file headers: it can be
  searched and yanked, and `virt_lines` cannot go above the first line anyway.
  Its kinds are outside `dlib.source_kinds`, so the gutter, highlight collection
  and `gf` pass over it without being told about it.
- **The stat is git's own**, from `git.commit_detail`, rather than counted from
  the view. It covers the binary files and renames the view leaves out, and it
  describes the commit rather than how the view is drawn, so `gw` leaves it
  alone. It compares the same range as the diff, so a merge's stat is against
  its first parent.
- **The message and stat are read once per sha** and kept in the session, since
  a commit cannot change.
- **It folds as one**, through `'foldexpr'` reading `header_rows`, and starts
  closed. Whether it was open is carried from one view to the next as a folded
  run's is; see [Folded unchanged lines](#folded-unchanged-lines).

#### What is compared with what

Everything downstream takes a `gitview.Range`, an old revision and a new one,
rather than a commit. The whole question of which parent a commit is compared
with then lives in `git.commit_range` and nowhere else.

`git log -z` gives each commit's parents, which is what decides that:

| parents | the range of one commit                         |
| ------- | ----------------------------------------------- |
| none    | `git diff-tree --root`, against the empty tree  |
| one     | that parent to the commit                       |
| several | the **first** parent to the commit              |

`git diff-tree -m` would have covered all three, but on a merge it concatenates
one diff per parent and `--no-commit-id` removes the headers that would tell the
blocks apart. `--first-parent` is a rev-list option that `diff-tree` rejects.
Naming the parent explicitly avoids the question, and both commands print the
same `--name-status` and `--numstat` records, so one pair of parsers reads both.

#### Two commits

`m` marks the commit under the cursor, and while a mark is set the pane shows
every row from the mark to the cursor. One mark rather than two: the far end is
marked and the near end is wherever the cursor goes, so a range is read by moving
rather than by a second key. The commits pane is short and a range is often long,
which is what makes moving the better half to leave free.

`m` only ever marks, moving the mark if it is elsewhere, and `<Esc>` clears it.
A toggle would make starting a range somewhere else two keys whenever the cursor
happens to be on the mark. `<Esc>` is commonly mapped globally already, and a
buffer-local map hides that for good, so with no mark to clear the pane runs the
global mapping itself (`util.run_global_map`).

- **Both ends are in the range.** It starts at the older end's first parent,
  the parent that commit is compared with on its own, so what is read is every
  row between the two, as a selection reads; the winbar writes it `older^..newer`.
  Starting at the older end itself, as `git diff older newer` would, left that
  commit out while its row looked as much a part of the range as the other end.
- **Which end is old follows from the list, not from the dates.** The list is
  newest first, so the row further down is the older side. A rebase or a
  cherry-pick can leave dates out of order, and the list is what is being read.
- **The cursor on the mark itself is the one commit**, against its own first
  parent, which is what a range of one row comes to anyway.
- **A root commit at the older end starts the range from the empty tree.** It
  cannot be left unnamed as for a root commit on its own: `git diff-tree --root`
  compares one commit with its parent, not two ends. The empty tree's sha is
  asked of `git hash-object`, since it differs between SHA-1 and SHA-256.
- **A merge inside a range is no special case.** A range compares two trees;
  only where it starts needs a parent chosen. This is the reason the range is
  the type everything takes.
- **A mark is dropped along with the list it pointed into.** A mark on a commit
  no longer listed would go on widening every range while no row showed where it
  was, so it is cleared whenever a re-read replaces the list without it — and only
  then, since a list that was [held back](#refreshing) still has the row.

A range whose ends sit on branches that diverged is compared all the same, and
said to have done so: `git merge-base --is-ancestor` decides whether the older
end is in the newer one's history, and if not the winbar reads
`(diverged; not one line of history)`. `git diff` compares the two trees either
way, but across a fork the result leaves the older end out and undoes whatever
its side did, which is not what "the changes between these two commits" sounds
like. Naming it is better than refusing a comparison that was asked for. The
answer is kept by the older end rather than by the range: two ends with one
parent start the same range, yet only one of them may lie on the line.

`git diff A...B`, which compares from the merge base instead, would have made
that case read as "what B added since they forked". It is not used, because it
would mean two rules for what a range means and the winbar could no longer state
the comparison as a pair of revisions.

#### The working-tree row

The list is headed by a row of zeros standing for the working tree. The use is
`git diff HEAD~4`: from some commit to the state of things now, committed or
not, read as a range like any other.

- **It is the newest end a range can have**, so it sits above the commits and is
  the new side whenever it is one end. `gitview.Range.new` is nil for it, which
  `git diff` given one revision already means, and `source.for_range` reads the
  new side from the files rather than the object database.
- **On its own it is not a range.** Against HEAD it would compare what the files
  pane already lists, so it shows that: every uncommitted file in one mixed view,
  staged and unstaged at once. `<CR>` there moves to the files pane rather than
  listing the same files a second time. Nothing is staged from it, since a
  partial stage reads the index contents of one file.
- **It is there even when nothing is uncommitted.** A clean working tree compares
  nothing HEAD's own row does not, but the row is still an end a range can be
  marked at. Such a range can be set up before anything is edited and follows
  the edits as they are made, and the commit rows do not shift as the row would
  come and go. It waits only for the status to be read and for a HEAD to exist;
  a mark on it goes while it is missing, as a mark on a commit goes with the list.
- **Untracked files are part of a range.** See
  [Untracked files in a range](#untracked-files-in-a-range).
- **Divergence is asked of HEAD.** The working tree stands on it, so a range
  ending there is one line of history exactly when its commit is an ancestor of
  HEAD.

#### Untracked files in a range

`git diff <rev>` compares only the paths the index names, so it would leave out
every file git is not tracking. The change list of a range ending at the working
tree is read against a copy of the index instead, with those files added to it as
intents to add (`git add -N`), and `GIT_INDEX_FILE` pointing the diff at the copy.

- **git treats them as any other file.** A path the old side had is a
  modification rather than a deletion beside an addition, a file moved without
  `git mv` is a rename, and binary detection is git's own.
- **The real index is never written.** The copy is thrown away afterwards, so
  nothing the user staged moves, and a write to the real index meanwhile cannot
  be undone by it.
- **The copy starts from the real index, not from nothing.** The diff lists the
  paths the index names, and an empty one would report every tracked file as
  deleted.
- **A stale copy gives the same answer.** It compares the old side with the
  working tree, and the index only decides which paths are looked at. git
  replaces the index by renaming a finished one over it, so the copy is never of
  a write under way.
- **The untracked files are the ones the status read found.** Listing them walks
  the whole working tree, which is too slow to repeat for every view.

#### Looking into one commit

`<CR>` sets the session's `scope` to whatever the cursor compares — one commit
or a marked range — and the commits pane is **replaced** by the files it
changed. The files pane above is left
alone, so what is uncommitted stays in view. Replacing rather than merging the
two lists is what a commit's `gitview.Change` and an uncommitted
`gitview.StatusEntry` being different shapes — one status letter against two, a
parent against three versions — makes right.

Which commit is being looked into is named by the pane's `'winbar'`, so no row of
the buffer stands for it and every row remains a file.

- **The change list is read once, on the way in, and kept**, along with the
  range it was read for. It is what the rows stand for and what each file's two
  versions are then read against, so selecting a file lists nothing again.
  `source.for_range_change` reads one entry of it the way `source.for_entry`
  reads one status entry.
- **A commit is immutable, so a refresh leaves the scope alone.** What is
  re-read is everything underneath, which is what backing out goes back to. A
  range ending at the working tree is the exception: its change list is read
  again, since the working tree may have moved on. The
  log is not even read while a range is in front of it, since the commits pane is
  showing the range's files; `<BS>` reads it on the way out.
- **`<BS>` backs out**, and the cursor lands on the commit it was on when going
  in — the near end of a range, not the mark — rather than wherever the row
  happens to fall. `q` still closes the
  session: a stack one level deep is not worth overloading it for.
- **`<CR>` inside a commit focuses the diff**, which is what it does in the files
  pane, since the row already names what is being shown.

`]f` and `[f` mean what the view is shaped like rather than where they are
pressed. A whole commit is many files in one buffer, so they scroll within it; a
single file — uncommitted or from a commit — is one of many rows, so they move
the list's cursor.

### Ignoring whitespace

`gw` stops lines that differ only in whitespace from counting as changed, and
turns it back on. It is session state rather than configuration — a way of
looking at one thing, changed and changed back while reading — and the configured
`ignore_whitespace` is only where it starts. `vim.diff` does the work; the option
had to be threaded through `dlib.hunks`, which builds its options table key by
key.

Two things have to be said out loud, because the fold is otherwise invisible:

- **The winbar reads `(whitespace ignored)`** for as long as it is on. A mode that
  silently changes which lines count as different is a trap.
- **A file whose only change is whitespace says `(no change outside whitespace)`**
  rather than `(no textual change)`, which would be a lie in exactly the case
  where the fold hides everything there was.

And **the row-level staging keys refuse while it is on.** A folded line is drawn
as `context`, which a mixed view reads from the index, so writing the shown rows
back would leave that line at its index version while the working tree kept the
other. Whole-file `s` is unaffected: it is `git add`, which reads no rows. The
measurement and the alternative are in
[staging.md](staging.md#ignoring-whitespace-and-the-rows-disagree).

The toggle lives on the session rather than in the configuration, because
changing it means building every view again from the sources. `ignore_whitespace`
in `setup()` only says where a session starts out.

### Changing the index

Two modules write to the index, and both hand back what they decided rather than
acting on it, so the decision can be tested without a repository:

- `stage.lua` picks the porcelain command that stages or unstages a whole file.
- `index.lua` assembles the index contents a set of diff rows implies, and writes
  them as a blob the entry is pointed at. No patch is generated anywhere.

[staging.md](staging.md) covers both in full: the commands, why `git apply
--cached` was not used, what a row's `side` decides, and where the approach has
holes. The parts that constrain the rest of the design are:

- **The session keeps the selected file's `index_lines`**, which is what
  `index.apply` writes the chosen rows into.
- **Whether the repository has a HEAD is a session-level flag**, re-read
  whenever the log is, because it decides which unstaging command is even
  available.
- **An unmerged file is listed but not drawn.** It has no stage 0 to read a
  version from, and writing one over a conflict's three entries reports no error
  and discards them. It is refused everywhere but whole-file `s`, which is
  `git add` resolving it. The view it needs is a
  [known gap](#a-merge-conflict-has-no-view).

After a change everything is rebuilt from git rather than adjusted in place: the
status letters, the file's three versions and which of its lines count as staged
all move together. The cursor follows what was selected rather than the row it
was on, by path for a file and by sha for a commit, because a file added or
committed away shifts every row below it. When the selection is gone altogether
each pane keeps the row it was on, clamped to what was just drawn.

### Refreshing

A session re-reads the repository on `R`, after it has changed the index itself,
and on its own from two triggers:

- **A poll on `<gitdir>/index`**, every second, which is what catches a change
  made while the session's own tab page is the one being looked at. `git add`,
  `git commit` and `git checkout` all write that file, so one watcher covers them
  whatever ran them: another terminal, a tmux pane, a script, another Neovim.
- **`TabEnter`**, which picks up whatever happened while another tab page was
  current, including the writes the poll passed over because nobody was looking
  at the session.

Two kinds of change fall between them, and are what `R` is left for:

- **A file written by something that never went through git**, by an external
  editor or a script. Neither the index nor HEAD moves. Watching the working tree
  instead is not on offer: `fs_event` does not recurse on Linux, and a watcher per
  directory of a repository is not worth what it would catch.
- **A command that moves HEAD without writing the index**: `git reset --soft`, an
  amend of nothing but the message, `git update-ref`. Watching `HEAD` as well
  would not settle this, since on a branch it is `refs/heads/<name>` that moves
  while `HEAD` holds still. In practice such a command is nearly always followed
  by one that does write the index, which is the next line redrawn.

Both are only a gap while the tab page stays current; entering it re-reads
regardless.

`FocusGained` would be the obvious third, and is deliberately not used. It needs
the terminal to report focus, which tmux does not do unless `focus-events` is on,
so it would be a trigger that silently never fires for some of the people it was
added for. The index poll covers what it was wanted for and does not wait for
Neovim to be given focus back.

The watcher polls rather than subscribing to filesystem events because git writes
`index.lock` and renames it over the index. The inode is replaced on every write,
so `fs_event` would be left holding a file nothing writes to again, while
`fs_poll` stats the path by name. The git directory is asked for rather than
assumed from the root, since `.git` is a file naming somewhere else in a worktree
and in a submodule.

`TabEnter` is global rather than a buffer event, so it is created once for the
module instead of once per session, and it acts on whichever session is current.
A session's own `tabnew` fires it before the session is registered, and so does
nothing. The watcher is the other way round — one per session, started with the
tab page and closed with it, since a poll handle is owned by nothing else.

Being triggered rather than asked for changes what a refresh may do:

- **It is throttled**, since `TabEnter` fires on every move between tab pages,
  including a glance at another one and straight back. One refresh is seven
  subprocesses and a view.
- **It reports nothing when git fails.** The trigger will come again, so a
  message per attempt would be noise rather than news. `R` still reports.
- **It keeps a diff the selection cannot have changed.** A commit or a range is
  named by sha, so what it compares is fixed; a file is named by its path alone,
  the working tree moves under it, and its view has to be built again. So does
  anything with the working-tree row at either end, whose name says as little. This is
  read from what is shown against `shown`, not from the target `sync_selection`
  derives, because those are compared by list index and one new commit moves every
  index below it.

The poll adds one more, because it is the only trigger that does not arrive at a
break in what the user is doing:

- **It waits for normal mode.** A redraw during a visual selection would take the
  lines being staged away from the command about to stage them. Dropping the
  refresh rather than deferring it costs nothing, since finishing that command
  re-reads anyway.

The line none of it may cross is changing what the diff pane shows. Nothing the
user did would account for it.

#### A commit the log has dropped holds the list back

Replacing the list is what would cross that line. The selection is re-derived
from the row the cursor is on, so a list that no longer names the selected commit
puts a different commit on that row and draws it instead.

The commit itself is still readable — a rewritten or reset commit stays in the
object database until it is pruned — so what is wrong is the list, not the view.
The old list is kept, the commits pane says `(history changed)` in its winbar, and
the first move off that commit lets the new list through, onto the row the cursor
chose rather than the one it happened to be on.

This only arises from a history rewrite or from a commit falling off the end of
the list. A commit merely added leaves the selected sha in place, where following
it by sha already finds it.

#### The files pane is allowed to drift

The same thing in the files pane is left alone. A file that has left the list has
genuinely stopped having changes, so there is nothing to go on showing, and moving
to the row that took its place is what a file manager does with a deleted file.
With nothing left at all the pane holds its empty notice and the diff says so too.

#### The status is read in the background

Listing untracked files walks the whole working tree, and in a large one
`git ls-files --others` alone takes a second. Every read of the status — opening
the tab page and every refresh — therefore runs its git commands through
`git.async`, and Neovim stays usable while they run:

- **Opening shows the commits at once.** The log is one cheap process, so it is
  read before the tab page is drawn, while the files pane holds a notice until
  the first read finishes. The cursor then lands on the first file, unless it has
  been moved to the commits in the meantime.
- **A refresh leaves the panes as they are** until its read finishes, and then
  redraws them as a synchronous refresh did.
- **Only the latest read is drawn.** Each one takes a number, and one that a
  later read has overtaken is dropped whichever finishes first, since it
  started from an older repository.
- **A first read that fails says so in the files pane.** A later one keeps the
  list already there, which is still the best there is.

`git.async` runs ordinary synchronous code in a coroutine and makes `git.run`
yield there rather than wait, so the readers in `status` and `git` are the same
functions either way, and a caller decides by how it calls them.

Staging is the one thing the wait changes. After `s` or `u` the panes show the
index as it was until the read catches up, and staging lines from them then
would write that old state back over the change just made. The session marks
itself `outdated` when it writes the index and refuses to stage again until a
read has drawn the result.

## Pipeline

For each file in the diff:

1. **Read the versions.** `diff/source` reads each one: a committed version from
   git, the index's from git, and the working tree's from the file's loaded
   buffer if it has one and from disk otherwise. git is only ever used to read
   blobs and to list what changed; the diff itself is `vim.diff`.
2. **Diff.** `lines.hunks()` returns raw hunk indices; `lines.build()` turns them
   into a flat list of context/deleted/added lines with both line numbers
   attached.
3. **Load ghost buffers.** Each whole version goes into its own scratch buffer,
   so the highlighter sees full context rather than a hunk fragment.

Then once for the whole view:

4. **Collect highlights** from the ghost buffers, for the rows the view shows.
   Tree-sitter is used when the language has a parser and legacy `:syntax`
   otherwise; both produce byte ranges paired with highlight groups, and nothing
   downstream knows which ran.
5. **Render**: write the source text, replay the highlights as extmarks, and
   layer diff backgrounds, word-level highlights and headers on top.
6. **Discard the ghost buffers.** They exist only for step 4.

The rows folded away are collected after every open row, a few files at a time
once the view is on screen. A view with many open rows is treated the same way:
its text and diff colors go on screen at once, and the syntax of its open rows
follows, starting from the file the cursor is in. `render.draw` owns the ghost
buffers from the moment it is called, and a step that finds its view replaced
frees them and stops.

Step 3 is what makes a line deleted from the middle of a multi-line string come
out as a string: the fragment alone carries no such information.

## Data shapes

### `gitview.Line`

One row of the rendered buffer.

- `text` — the source line, exactly as it appears in the buffer
- `kind` — `context`, `add` or `del`
- `old_lnum` / `new_lnum` — line numbers in each version; `nil` on the side
  where the line does not exist
- `side` — which version `text` came from, `old` or `new`
- `row` — 0-based row of `text` in that version's ghost buffer
- `file` — index into `View.files`
- `index_pos` — where the row sits in the index; a mixed view only

`side` plus `row` plus `file` is what links a rendered row back to the ghost
buffer its highlights come from. `old_lnum` / `new_lnum` are for display and for
opening the source; they are not used for highlighting. `index_pos` is there
for writing the index back: see `diff/mixed` for how every row is placed against
it, including the rows the index does not have.

### `gitview.View`

Everything one diff buffer needs, stored in `render.views[bufnr]` and dropped on
`BufWipeout`.

- `lines` — the `gitview.Line[]`, one per buffer row
- `files` — `gitview.File[]`, each with its ghost buffers, language, label, and
  the 1-based row of its header line
- `hunk_rows` — 1-based rows to jump between with `]h` / `[h`
- `rev`, `note` — shown in the winbar
- `header_rows` — how many rows at the top are a commit's header; `nil` when
  there is none

Rows in `hunk_rows` and `files` are absolute in the combined buffer. Assembling
several files means concatenating each file's lines and shifting its rows by the
running offset, and `view.prepend` shifts them all once more for a header.

### Line kinds

Every buffer row has a `gitview.Line`, but only some of them stand for a line of
one of the two versions:

| kind                     | text                       | has line numbers |
| ------------------------ | -------------------------- | ---------------- |
| `context`, `add`, `del`  | source text                | yes              |
| `file`                   | the file's label           | no               |
| `blank`                  | empty, separates two files | no               |
| `subject`, `author`      | a commit's header          | no               |
| `body`, `stat`           | a commit's header          | no               |

`dlib.source_kinds` is the test for the first group. Anything that looks a line
up in a ghost buffer, prints a gutter, or opens the source has to check it
first, because the other kinds carry no `side`, `row` or `file`.

### Folded unchanged lines

Every line of every version is in the view. The unchanged lines away from any
change — all but `context` of them on each side of a change, and all of them
before the first and after the last — are marked `folded`, and each run of them
is one closed fold.

- **Folding rather than dropping** lets a reader open a run to see what the
  change sits in, and lets a search find a line that is not in view.
- **A run of one line is left open.** A closed fold still takes a row, so folding
  a single line away saves nothing and hides the line.
- **A closed run reads as its first line that is not blank**, indented as it is
  in the file and colored by its syntax, followed by how many lines it holds.
  It is the only hint of what the run hides without opening it. Tabs are
  expanded and a long line is cut, so that the count always fits.
- **The rest of a closed fold is `'fillchars'` fold**, the user's own, for a run
  and for a commit's header alike, so a closed fold spans the window and is
  hard to miss.
- **The gutter is blank on a closed run**, which stands for several lines rather
  than for its first.
- **Their syntax comes last.** The folded rows cover whole files, so they are
  collected after every open row, in the background; a run shown or opened
  before then shows its colors a moment late.

Folds are an expression reading the view rather than manual folds, because a
manual fold would be lost every time the lines are replaced. Replacing them
under an open fold leaves it open or closes it depending on how its extent
changed, so `render.draw` records which folds were open in each window and
restores that. A fold is recognised in the next view by the file and the new
line number of its first row — or as the header — which stays put while
staging redraws the same file. A fold with no counterpart follows
`'foldlevel'`.

## Layering

Everything drawn is an extmark, ordered by priority:

| priority | layer                                        |
| -------- | -------------------------------------------- |
| 10       | Added/deleted line background, with `hl_eol` |
| 100      | Replayed syntax highlighting, the stat graph |
| 200      | Word-level change highlights                 |

The ordering is the point: the line background has to sit under the syntax
colors so they survive, and the word-level highlights have to sit over both so a
changed word stands out against its own line's background.

File headers are ordinary buffer lines, highlighted by the same whole-line
range marks as the diff colors. They were virtual lines once; making them real
means they can be searched, jumped to by row, and copied along with the lines
around them, and it removes the special cases that `virt_lines` above line 1
forced (see `neovim-notes.md`).

Two things are still deliberately _not_ buffer text:

- the gutter, drawn with `'statuscolumn'`, so line numbers stay out of a yank
- the name of the file the cursor is in, drawn in the `'winbar'`

The winbar is recomputed on redraw rather than set once, so it follows the cursor
through a multi-file view and keeps naming the file after its header line has
scrolled off.

## Mixed view

An uncommitted file's diff replaces step 2 of the pipeline with `mixed.build`,
which takes three versions of the file instead of two. The rest of the pipeline
is unchanged apart from a third ghost buffer for the index.

### Aligning on the index

`mixed.merge` diffs HEAD -> index (the staged changes) and index -> working tree
(the unstaged ones). Both diffs share the index as one of their sides, so every
index line is placed by both at once. Each row then falls into one case:

| HEAD | index | work | `kind`    | `stage`    |
| ---- | ----- | ---- | --------- | ---------- |
| yes  | yes   | yes  | `context` | —          |
| yes  | —     | —    | `del`     | `staged`   |
| —    | yes   | yes  | `add`     | `staged`   |
| yes  | yes   | —    | `del`     | `unstaged` |
| —    | —     | yes  | `add`     | `unstaged` |
| —    | yes   | —    | `del`     | `index`    |

- `old_lnum` is the HEAD line number and `new_lnum` the working-tree one, as in
  an ordinary view. An `index` row has neither.
- A line in HEAD and the working tree but not the index is not a case of its
  own. It comes out as a staged deletion plus an unstaged addition.
- Rows are read from the index ghost buffer (`side = 'index'`) whenever the
  index has the line, and from HEAD or the working tree otherwise.

### Ordering between index lines

Between two index lines there can be HEAD lines the index dropped and
working-tree lines the index lacks. They are normally emitted deletions first.
The exception is when the index line above was itself removed from the working
tree. The additions then replace that line, so they come first. Otherwise a
partially staged hunk interleaves the two layers:

```
- a      (unstaged)      - a      (unstaged)
- b  S                   + A      (unstaged)
+ A      (unstaged)      - b  S
+ B  S                   + B  S
  wrong                    right
```

### Pairing

`change_pairs()` only pairs a deletion and an addition of the same `stage`.
Across stages they are two separate changes, and a word diff between them
would compare HEAD with the working tree past the index.

### File list

`status.list` names the files. A file appears when `git diff --cached`,
`git diff` or `git ls-files --others` lists it, and it appears once however
many of them do: the first two are joined on the index path, which is the only
name both use for a file renamed in the index.

Each entry keeps the status letter of either side, as `git status --short`
prints them, but nothing downstream branches on it. The diff is built from HEAD,
the index and the working tree whatever changed, and a version the file does not
have is empty — an untracked file has neither of the first two. A file with only
staged changes has a working tree equal to its index, and one with only unstaged
changes has a HEAD equal to its index, so neither is read twice.

Binary files are excluded. git flags the tracked ones through
`git diff --numstat`; it never diffs an untracked file, so those are recognised
the way git itself does it, by a NUL byte in the first 8000 bytes.

## Invariants

Each of these is guarded by a test. Breaking one is a regression even if
everything still looks right.

| invariant                                                               | guarded by                                       |
| ----------------------------------------------------------------------- | ------------------------------------------------ |
| Buffer text equals source text, row for row                             | `render_spec`, `multifile_spec`                  |
| Hunk boundaries match `git diff`                                        | `diff_spec`                                      |
| No line is emitted twice, and line numbers only increase                | `diff_spec`                                      |
| Highlight ranges stay inside their line and on character boundaries     | `render_spec`, `worddiff_spec`, `highlight_spec` |
| Restricting collection to some rows does not change what those rows get | `highlight_spec`                                 |
| Colors work without `setup()` ever being called                         | `render_spec`                                    |
| Word-level pairing never crosses a file boundary                        | `diff_spec`                                      |
| Word-level pairing never crosses a stage boundary                       | `mixed_spec`                                     |
| Unstaging a rename leaves the index equal to HEAD                       | `stage_spec`                                     |
| An unmerged path is never written to the index                           | `session_spec`                                   |
| A merge is compared with its first parent only when shown alone           | `git_spec`, `session_spec`                        |
| A range across a fork is compared, and said to be across one             | `git_spec`, `session_spec`                        |
| A commit's view reads neither side from the working tree                | `session_spec`                                   |
| Nothing is staged while a commit or one of its files is selected        | `session_spec`                                   |
| Looking into a commit replaces the commits pane, not the files pane      | `list_spec`, `session_spec`                      |
| The diff pane restarts at the top unless it is redrawing the same thing  | `session_spec`                                   |
| Staging every unstaged row leaves nothing unstaged                      | `index_spec`                                     |
| Rows are never written to the index while whitespace is ignored          | `session_spec`                                    |
| Unchanged lines are folded, never dropped                               | `diff_spec`, `mixed_spec`                        |
| An opened fold stays open while the same file is redrawn                | `session_spec`                                   |

## Deliberate omissions

Alternatives that were tried or considered and rejected, so they are not
re-attempted by accident:

- **Generating a patch and running `git apply --cached`.** See
  [staging.md](staging.md#why-not-git-apply---cached).
- **Parsing `git diff` output instead of using `vim.diff`.** Workable, and it
  would inherit the user's git configuration, but git compares the file on disk
  while this compares the buffer. `vim.diff` already agrees with git on hunk
  boundaries once `linematch` is off.
- **`linematch` on by default.** It improves word-level pairing but disagrees
  with `git diff`. It is configurable; the default favours agreement.
- **Character-level word diff.** Unrelated lines share letters, so the result
  reads as noise. Tokens are runs of word characters instead.
- **`line_hl_group` for the line background.** See [neovim-notes.md](neovim-notes.md).
- **`vim.inspect_pos()` for collecting highlights.** See the same document.

## Known gaps

### A merge conflict has no view

An unmerged file is listed and then says `(unresolved conflict)` where its diff
would be. That notice is a placeholder for a view that does not exist yet, not a
decision that a conflict has nothing worth showing. Everything it needs is in the
index already, as merge stages 1, 2 and 3.

A mixed view is the wrong shape for it, for two independent reasons.

- **There is no staged layer to show.** A path has either stage 0 or stages 1–3,
  never both: `git add` on an unmerged path is what collapses the stages into
  stage 0, so resolving and staging are the same act. The question a mixed view
  exists to answer — staged or unstaged — does not arise.
- **The three versions fork rather than chain.** `HEAD -> index -> work` is a
  chain, and which versions hold a line maps onto staged and unstaged.
  `ours <- base -> theirs` has one common ancestor, and the same fact maps onto
  ours, theirs and both. git draws its own distinction here: `git diff` on an
  unmerged path emits a combined diff, `@@@` with two marker columns, rather than
  an ordinary one.

So the display, the gutter legend, the winbar and the keys all differ — take
ours, take theirs, take both, rather than stage and unstage. It is a sibling of
the mixed view, not a setting of it.

What carries over and what does not:

- `mixed.align` is reusable as it stands. It turns a hunk list into a line
  correspondence and assumes nothing about what the two sides are.
- `mixed.merge` is not. Its pivot is the new side of one diff and the old side of
  the other, so it reads `staged.new_to_old` and `unstaged.old_to_new`. A merge
  pivots on base, which is the old side of **both** diffs. The assembly is the
  same shape written against different tables.
- **Not all three stages exist.** Each can be missing, and the status pair names
  which: `AA` has no base, `DU` no ours, `UD` no theirs. Treating a missing stage
  as empty is what the pipeline already does for a version a file does not have.

Reading `git ls-files -u` is what a merge view needs, and it also yields the
exact status pair, so the present rounding of every conflict to `UU` is resolved
by the same work.

### Word-level pairing needs equal-sized blocks

`change_pairs()` matches deleted lines to added ones by position, so a block
replaced by one of a different size gets no word-level highlights at all.
Matching them by similarity instead would lift that, and unlike enabling
`linematch` it would not move any hunk boundary: which lines are compared for
word highlights is independent of how the diff is laid out.
