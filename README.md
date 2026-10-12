# gitview.nvim

A Git view for Neovim: uncommitted changes and recent commits in a sidebar, and
a GitHub-style unified diff beside it. Deleted and added lines share one column,
both syntax highlighted, and the buffer is still just text you can select, yank
and search.

Requires Neovim 0.12+. Highlighting uses Tree-sitter where a parser exists and
falls back to legacy `:syntax` otherwise, so any language Neovim can colorize
works.

## Usage

```vim
:GitView    " open a tab page with the sidebar and the diff
```

`:GitView` is the only command; everything else is done inside the tab page it
opens, described under [The tab page](#the-tab-page) below.

```lua
require('gitview').setup({
  context = 3,             -- unchanged lines left open around each hunk
  algorithm = 'histogram', -- vim.diff() algorithm
  linematch = 0,           -- see "Agreement with git diff" below
})
```

## How it works

A diff buffer interleaves two versions of a file, so its text is not valid
source in any language and no parser can highlight it directly. Highlights are
instead collected from separate scratch buffers holding each whole version, then
replayed onto the diff buffer as extmarks. Line numbers are decoration rather
than text, so yanking a selection gives you code and not a gutter.

There is no `+`/`-` column. A deleted line has only its old number, painted
red, and an added line only its new number, painted green.

[docs/architecture.md](docs/architecture.md) describes the pipeline in full.

### Several files in one buffer

A commit, a range of commits, or the working tree as a whole is shown with every
changed file's diff laid out end to end in one buffer, each file highlighted with
its own language.

- The working tree is read from disk, as git sees it. Unsaved edits in a buffer
  are not part of the diff until they are written.
- Added, deleted and renamed files are all handled.
- Binary files, changes with no textual difference such as a pure rename, and
  conflicted files with no conflict markers have no lines to show. They are
  listed by name at the top of the diff, below a commit's header, rather than
  dropped silently.

### Staged and unstaged in one view

Uncommitted changes are shown as one diff from HEAD to the working tree, with
each changed line marked by whether it is staged. Staging from this view is
described under [The tab page](#the-tab-page).

Untracked files are included, every line of them an unstaged addition. Binary
ones are left out, as they are elsewhere; since git never diffs an untracked
file, they are recognised the way git itself does, by a NUL byte near the start.

The gutter reads `HEAD lnum | working-tree lnum | bar`. Line numbers are those
of HEAD and the working tree, so a line in neither has none. Two things mark a
changed line:

- **A `┃` bar** marks a line the index has changed, which unstaging would take
  back. It is green for a line the index added and red for one it deleted.
- **The diff colors** mark a line the working tree has changed since the index,
  which staging would record. A line with the bar and no further change has the
  same colors blended into the background instead.

| line                                    | bar   | background |
| --------------------------------------- | ----- | ---------- |
| deletion or addition, staged            | `┃`   | blended    |
| deletion or addition, not staged        |       | diff color |
| staged addition, removed from work tree | green | red        |

The last one is the one to watch for. The line would be committed, yet the
working tree no longer has it. It appears when a staged line is edited again or
reverted without re-staging, and is the only row with a bar and no number.

Two situations show changes even though HEAD and the working tree are equal,
because the index differs from both:

- A staged change reverted in the working tree: a staged deletion of the HEAD
  line, the index line with its green bar on red, then an unstaged addition of
  the working-tree line.
- A staged deletion restored in the working tree: a staged deletion then an
  unstaged addition of the same text. The index has no row for the line, so it
  cannot show as unchanged.

How the three versions are merged is described in
[docs/architecture.md](docs/architecture.md#mixed-view).

### Merge conflicts

A file with an unresolved conflict is shown as the working tree has it, conflict
markers included, rather than as a diff. It is read-only like any other diff.

- **Only the lines around each conflict are open**, and the rest is folded as
  unchanged lines are. `]c` and `[c` move between the conflicts.
- **Each part of a conflict has a background of its own**: ours, theirs, the base
  that `diff3` and `zdiff3` add. Each marker has a stronger one: those opening
  a part and `>>>>>>>` in that part's hue, and `=======` in one of its own. Ours
  and theirs are not drawn as an addition and a deletion, since neither replaces
  the other.
- **The gutter has the working tree's line numbers only**, so `gf` opens the file
  on the line under the cursor, to edit it there.
- **The file's header counts conflicts** where it would count lines, as `!2`.
- **Syntax comes from the working tree, markers and all.** The markers themselves
  are left uncolored. Code inside or just after a conflict can be colored wrongly,
  since the file with its markers is not valid code.

A conflict is resolved by editing the file and pressing `s` on it in the list,
which is `git add`. Its lines cannot be staged from the diff, since the index has
no single version of the file to stage them into. A conflicted file with no
markers left to show, such as one that one side deleted, says so in place of the
view.

How the markers are recognised is described in
[docs/architecture.md](docs/architecture.md#conflict-view).

### The tab page

`:GitView` opens a tab with a sidebar on the left and the diff on the
right. The sidebar is split in two: the uncommitted changes above, the recent
commits below. Moving the cursor in either draws whatever it lands on, and moving
between the two panes switches which list the diff follows. The row the diff is
showing has its name colored, and only in the pane it follows, so which one that
is can be read even while the focus is in the diff.

The tab keeps up with the repository on its own. Anything that writes the index
— `git add` in another terminal, a commit from a tmux pane, a branch switch from
a script — is noticed within a second and redrawn, and coming back to the tab page
re-reads it as well.

`R` re-reads it on demand, for what those two miss while you stay on the tab page:
a file written by something that never touched git, and the few commands that move
HEAD without writing the index, such as `git reset --soft`.

There is one tab page per repository. Running `:GitView` again in the same
repository goes back to the one already open rather than opening another.

The upper pane has one row per file, with the two status letters
`git status --short` prints. A file changed both in the index and in the working tree is still one
row, and its diff is the mixed view above: what is staged and what is not, at
once. Only the letters are drawn; the row itself is the path, so yanking one
gives something pasteable.

#### Files as a tree

With `list_style = 'tree'`, the files pane and the files of a commit looked into
are laid out as a tree instead, under a root row `./`:

```
▼ ./
 M README.md
▼ lua/gitview/
│  M init.lua
│ ▼ ui/
│ │  M list.lua
```

The status letters move from the left edge to the front of each name, where they
stay next to it however deep the file is. The rows are still whole paths, with
the parent directory's part hidden and the letters only drawn, so yanking one
still gives the full path. A directory holding nothing but another
directory shares its row, as `lua/gitview/` does. The root's files sit beside it
rather than below, so no row loses width to a level that is always there.

The order is git's, not a file manager's: directories are not put first, and
`a.lua` comes before `a/`. It is the order `git diff` lists the files in, and the
order `]f` and a multi-file diff go by.

A directory row shows the diff of every file in it, and the root that of every
file listed, once the cursor has rested on it for a moment. Lines cannot be
staged in it; `s` and `u` on the row take every file in the directory instead.
A directory holding an unresolved conflict is refused either way, since staging
the conflicted file would mark it resolved unseen.

```lua
require('gitview').setup({ list_style = 'tree' }) -- 'flat' by default
```

#### Recent commits

The lower pane lists the most recent commits, and putting the cursor on one draws
what that commit changed. It is the ordinary diff of
[several files in one buffer](#several-files-in-one-buffer), not a mixed view:
both sides are committed, so nothing there is staged or unstaged. A merge
is compared with its first parent, the way `git show` does, and the winbar says
`first parent`. A subject too long for the winbar is cut short with `…`, so the
file and the sha beside it stay in view.

Above the diff is what `git show --stat` would print before it: the subject, the
author and date, the body, and the stat. Below the subject, it starts folded
into a single line with who wrote it how long ago and the size of the commit,
its line counts in the gutter as a file's header has them; the commits pane has
no room for the author, so this is where it is read. The
subject is left out of the fold, so a long one never hides the rest. `zo` on the
folded line opens it, and a header opened stays open as the cursor moves on to
other commits. A range of two commits has no one message and shows no header.

A commit row states its own sha and subject, so yanking one gives something that
names the commit elsewhere. Only the first four characters of the sha are shown,
to leave the narrow sidebar to the subject; the rest is concealed rather than
dropped, so what is yanked is still the sha git abbreviates to. Two keys mean less there and say so rather than
acting: `s` and `u` have nothing to stage.

`<CR>` on a commit goes one level in: the pane is replaced by the files that
commit changed, and selecting one shows that file's diff by itself. The
uncommitted changes above stay in view. `<BS>` comes back out, onto the commit you
were looking at. `R` in there re-reads the uncommitted state; the commit itself
cannot change.

#### Comparing two commits

`m` marks the commit under the cursor. While a mark is set, moving the cursor
shows every commit from the mark to the cursor in one diff, so a range is read by
moving rather than by marking twice. Those rows are colored as a selection is,
and the winbar counts them. `m` on another commit moves the mark there, and
`<Esc>` clears it; with no mark set, `<Esc>` does whatever it is mapped to
elsewhere.

Both ends are in the range, as in a selection: the diff starts at the first
parent of the older end, the parent that commit is compared with on its own, and
the winbar names it `older^..newer`. Which end is the older one follows from the
list rather than from the dates: the list is newest first, so the row further
down is the older side. The cursor on the mark itself is a range of one commit,
the same as no mark at all. `<CR>` works the same way, so a range can be opened
a file at a time.

A merge inside a range is nothing special — a range compares two trees, and only
where it starts is chosen by first parent. What does need saying is a range
whose ends are on branches that diverged: the older end is then not in the
newer one's history, the diff leaves it out and undoes whatever its branch did,
and the winbar says `diverged` rather than passing it off as a stretch of
history.

#### Comparing with the working tree

The list is headed by a faded row of zeros standing for the working tree. On its
own it shows every uncommitted file in one view, staged and unstaged at once, and
`<CR>` there moves to the files pane.

It is also an end a range can have, and the newest one. `m` on `HEAD~3` with the
cursor on the zeros reads that commit and everything since, committed or not, the
way `git diff HEAD~4` does; `<CR>` then lists those files. Untracked files are
compared too, as additions, which `git diff` itself would leave out. The row is
there even when nothing is uncommitted, so such a range can be set up first and
then follows the edits as they are made.

| key         | in the files pane   | in the commits pane  | in the diff                   |
| ----------- | ------------------- | -------------------- | ----------------------------- |
| `<CR>`      | focus the diff      | look into the commit |                               |
| `<BS>`      |                     | back out of it       |                               |
| `m`         |                     | mark, for a range    |                               |
| `<Esc>`     |                     | clear the mark       |                               |
| `gw`        | ignore whitespace   | ignore whitespace    | ignore whitespace             |
| `s`         | stage file / dir    |                      | stage the line or selection   |
| `u`         | unstage file / dir  |                      | unstage the line or selection |
| `S` / `U`   |                     |                      | stage / unstage this hunk     |
| `]f` / `[f` |                     |                      | next / previous file          |
| `]c` / `[c` |                     |                      | next / previous hunk          |
| `gf`        | open the file       | open the file        | open the file at this line    |
| `R`         | re-read             | re-read              |                               |
| `q`         | close               | close                | close                         |

`gf` opens the file in the tab page `:GitView` was first run from, and leaves the
session open to come back to. From the diff it lands on the line under the
cursor; a deleted line lands on the line now in its place. A commit's line
numbers are the commit's, so there it lands near the line rather than on it.

There is one key per direction rather than one key toggling: a file changed in
the index and in the working tree both has no obvious sense in which it is
staged or not, and a row here states that state rather than hiding it.

Where the key is pressed decides what it acts on. In the list, `s` and `u` take
the whole file, or every file of a directory in a tree. In the diff they take
the row under the cursor, or the rows a visual selection covers, and `S` and `U`
take the whole change the cursor is in.
Both panes are re-read from git afterwards.

Because the diff is a mixed view, the two directions are never ambiguous even
inside one hunk: `s` acts on the rows that are not staged yet and `u` on the
rows that are.

Binary files and changes with no lines to them, such as a pure rename, are
listed and say as much in place of a diff. Discarding changes and committing are
not implemented.

#### Ignoring whitespace

`gw`, from any of the three windows, stops lines that differ only in whitespace
from counting as changed. The winbar says `space ignored` while it is on, and a
file whose only change is whitespace says so rather than claiming to have no
change at all. `gw` again puts it back.

While it is on, `s` and `u` **in the diff** refuse: a folded line is drawn as
context, taken from the index, so staging the rows on screen would write that
version back and leave the file still modified. `s` and `u` in the files pane are
unaffected — they run `git add`, which takes the file as it is.

```lua
require('gitview').setup({
  list_ratio = 0.25,        -- share of the width the sidebar takes, 30 columns at least
  commit_count = 100,       -- how many recent commits it lists
  commit_ratio = 0.4,       -- share of the sidebar height the commit list takes
  ignore_whitespace = false, -- where every diff starts out
})
```

### Filetypes left unhighlighted

A language without a Tree-sitter parser is highlighted through its Vim syntax
file, which is loaded again for both versions of every such file in a view. Some
are slow to load, especially with many highlight groups defined, and a commit
touching many of them can take noticeably longer to open. Listing a filetype
shows its diffs with the diff colors only:

```lua
require('gitview').setup({ no_highlight = { 'scss' } })
```

Installing the language's Tree-sitter parser avoids the cost without giving up
the colors.

### Agreement with `git diff`

Hunk boundaries match `git diff`, because Neovim's `linematch` pass — which
re-pairs lines inside a hunk and splits it, disagreeing with git — is left off.
It can be turned on at the cost of that agreement:

```lua
require('gitview').setup({ linematch = 60 })
```

Both sides of the trade-off are measured in
[docs/neovim-notes.md](docs/neovim-notes.md#linematch-disagrees-with-git).

### Highlight groups

`GitViewAdd`, `GitViewDelete`, `GitViewAddText`, `GitViewDeleteText`,
`GitViewOldLnum`, `GitViewNewLnum`, `GitViewAddLnum`, `GitViewDeleteLnum`,
`GitViewSeparator`, `GitViewFileHeader`. The rows of an opened fold are marked
in the gutter with `GitViewFoldBar`.

The mixed view adds `GitViewStagedAdd`, `GitViewStagedDelete`,
`GitViewStagedAddText`, `GitViewStagedDeleteText`, `GitViewStagedAddBar` and
`GitViewStagedDeleteBar`.

A conflicted file's lines use `GitViewConflictOurs`, `GitViewConflictTheirs` and
`GitViewConflictBase`, and its markers `GitViewConflictOursMarker` (`<<<<<<<`),
`GitViewConflictBaseMarker` (`|||||||`), `GitViewConflictSeparator` (`=======`)
and `GitViewConflictTheirsMarker` (`>>>>>>>`).

A file's header is painted across the window, gutter included, with
`GitViewFileHeaderBg`, and its gutter counts with `GitViewFileHeaderStatAdd`
and `GitViewFileHeaderStatDelete`, or with `GitViewFileHeaderConflictCount` for
a conflicted file. A commit's header uses
`GitViewCommitSubject`, `GitViewCommitAuthor`, `GitViewStatAdd` and
`GitViewStatDelete`. The files a diff leaves out are listed in `GitViewSkipped`.

The sidebar uses `GitViewStatusStaged`, `GitViewStatusUnstaged`,
`GitViewStatusUntracked`, `GitViewCommitSha`, `GitViewCommitWorktree`,
`GitViewListCursor`, `GitViewRange` and, in a tree, `GitViewDirectory` and
`GitViewIndent`.
`GitViewCommitSha` colors the shas in the diff's winbar as well.

The diff colors default to backgrounds derived from `DiffAdd`/`DiffDelete`,
the conflict colors to fixed hues blended into the `Normal` background,
`GitViewFileHeaderBg` to one derived from `CursorLine`, and the rest link to standard groups. All are defined the first time they are
needed, and are redefined on `ColorScheme`.
Defining any of them yourself takes precedence. `setup()` is optional: it only
carries configuration, and the colors do not depend on it.

## Known limitations

- **No LSP semantic tokens.** The scratch buffers have no language server
  attached, so highlighting is purely syntactic.
- **Languages without a Tree-sitter parser need `:syntax` enabled.** They fall
  back to it, and a Tree-sitter-only setup gets no colors there. Highlighting
  them is also slower.
- **The winbar can be taken over by your config.** The file at the top of the
  window is reported through `'winbar'`, so a configuration or plugin that sets
  it for every window hides it. Every file still has its own header line in the
  buffer.
- **A merge conflict can only be read, not merged.** There are no keys to take
  one side or the other; the file is edited after `gf`, and marked resolved with
  `s` on it in the list. It is listed as `UU` whichever pair git would print, and
  its syntax colors can be off around a conflict. See
  [docs/architecture.md](docs/architecture.md#a-conflict-is-shown-not-merged).
- **A range ending at the working tree shows conflict markers as added lines.**
  `git diff <commit>` reports an unmerged file as an ordinary change, and the
  markers are in the working tree.
- **A file with no trailing newline gains one** if part of it is staged. Nothing
  here can represent a missing final newline: a blob is read as a line array and
  written back as one.
- **Everything is computed eagerly** when the diff opens, and grows linearly
  with the number of files. See [docs/performance.md](docs/performance.md) for
  the numbers.

## Development

```sh
make test
```

| document | what it covers |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | The pipeline, the modules, the data shapes, and the invariants |
| [docs/neovim-notes.md](docs/neovim-notes.md) | Neovim and git behaviours the code depends on, and why the obvious alternatives were rejected |
| [docs/staging.md](docs/staging.md) | How the index is written, why not with a patch, and where that has holes |
| [docs/performance.md](docs/performance.md) | Where the time goes, measured, and how to measure it again |
| [docs/testing.md](docs/testing.md) | How the suite runs and how to add to it |
