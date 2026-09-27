# unidiff.nvim

> [!WARNING]
> **This README is out of date.** `:Unidiff`, `:UnidiffAll` and `:UnidiffMixed`
> have been removed; `:UnidiffStatus` is now the only entry point, and every
> feature is offered inside the tab page it opens. The sections below still
> describe the old commands. [docs/](docs/) is up to date.

A GitHub-style unified diff view for Neovim: deleted and added lines in one
column, both syntax highlighted, and the buffer is still just text you can
select, yank and search.

Requires Neovim 0.12+. Highlighting uses Tree-sitter where a parser exists and
falls back to legacy `:syntax` otherwise, so any language Neovim can colorize
works.

## Usage

```vim
:Unidiff          " diff the current buffer against HEAD
:Unidiff HEAD~3   " ...or against any revision

:UnidiffAll       " every changed file, in one buffer
:UnidiffAll main  " ...against any revision

:UnidiffMixed     " experimental: staged and unstaged changes in one view

:UnidiffStatus    " work in progress: uncommitted changes, and recent commits
```

```lua
require('unidiff').setup({
  context = 3,             -- unchanged lines kept around each hunk
  rev = 'HEAD',            -- default revision to diff against
  algorithm = 'histogram', -- vim.diff() algorithm
  linematch = 0,           -- see "Agreement with git diff" below
})
require('unidiff').open({ rev = 'main', context = 5 })
require('unidiff').open_all({ rev = 'main' })
```

Inside the diff buffer:

| key    | action              |
| ------ | ------------------- |
| `]h`   | next hunk           |
| `[h`   | previous hunk       |
| `]f`   | next file           |
| `[f`   | previous file       |
| `<CR>` | jump to source line |
| `q`    | close               |

## How it works

A diff buffer interleaves two versions of a file, so its text is not valid
source in any language and no parser can highlight it directly. Highlights are
instead collected from separate scratch buffers holding each whole version, then
replayed onto the diff buffer as extmarks. Line numbers and `+`/`-` markers are
decoration rather than text, so yanking a selection gives you code and not a
gutter.

[docs/architecture.md](docs/architecture.md) describes the pipeline in full.

### Several files in one buffer

`:UnidiffAll` lays every changed file's diff out end to end in one buffer, each
file highlighted with its own language.

- The new side is a **loaded buffer's contents** when the file is open, and the
  file on disk otherwise, so unsaved edits show up.
- Added, deleted and renamed files are all handled.
- Binary files, and changes with no textual difference such as a pure rename,
  have no lines to show. They are counted in the winbar rather than dropped
  silently.

### Staged and unstaged in one view (experimental)

`:UnidiffMixed` shows every uncommitted change as one diff from HEAD to the
working tree, with each changed line marked by whether it is staged. It is
read-only; nothing is staged or unstaged from the view.

Untracked files are included, every line of them an unstaged addition. Binary
ones are left out, as they are elsewhere; since git never diffs an untracked
file, they are recognised the way git itself does, by a NUL byte near the start.

The gutter reads `HEAD lnum | working-tree lnum | mark | sign`. Line numbers
are those of HEAD and the working tree, so a line in neither has none.

| gutter | line exists in   | meaning                                    |
| ------ | ---------------- | ------------------------------------------ |
| `S-`   | HEAD             | deletion, staged                           |
| `S+`   | index, work tree | addition, staged                           |
| ` -`   | HEAD, index      | deletion, not staged                       |
| ` +`   | work tree        | addition, not staged                       |
| `I-`   | index            | staged addition, removed from work tree    |

- **`S`** lines have faded colors: they are what a commit would record now.
- **Unmarked** lines look as they do in `:UnidiffAll`: they are what a commit
  would still leave out.
- **`I-`** is the one to watch for. The line would be committed, yet the
  working tree no longer has it. It appears when a staged line is edited again
  or reverted without re-staging.

Two situations show changes even though HEAD and the working tree are equal,
because the index differs from both:

- A staged change reverted in the working tree: `S-` (HEAD), `I-` (index),
  then `+` (working tree).
- A staged deletion restored in the working tree: `S-` then `+` with the same
  text. The index has no row for the line, so it cannot show as unchanged.

How the three versions are merged is described in
[docs/architecture.md](docs/architecture.md#mixed-view).

### The status tab (work in progress)

`:UnidiffStatus` opens a tab with a sidebar on the left and the diff on the
right. The sidebar is split in two: the uncommitted changes above, the recent
commits below. Moving the cursor in either draws whatever it lands on, and moving
between the two panes switches which list the diff follows.

The upper pane has one row per file, with the two status letters
`git status --short` prints. A file changed both in the index and in the working tree is still one
row, and its diff is the mixed view above: what is staged and what is not, at
once. Only the letters are drawn; the row itself is the path, so yanking one
gives something pasteable.

#### Recent commits

The lower pane lists the most recent commits, and putting the cursor on one draws
what that commit changed. It is the ordinary diff of `:UnidiffAll`, not a mixed
view: both sides are committed, so nothing there is staged or unstaged. A merge
is compared with its first parent, the way `git show` does, and the winbar says
so.

A commit row states its own sha and subject, so yanking one gives something that
names the commit elsewhere. Two keys mean less there and say so rather than
acting: `s` and `u` have nothing to stage, and `<CR>` in the diff has no
working-tree line to jump to, because the line numbers are the commit's.

`<CR>` on a commit goes one level in: the pane is replaced by the files that
commit changed, and selecting one shows that file's diff by itself. The
uncommitted changes above stay in view. `<BS>` comes back out, onto the commit you
were looking at. `R` in there re-reads the uncommitted state; the commit itself
cannot change.

#### Comparing two commits

`m` marks the commit under the cursor, and `>` appears in its gutter. While a
mark is set, moving the cursor compares the mark with whatever it lands on, so a
range is read by moving rather than by marking twice. `m` again on the marked
commit clears it.

Which end is the old one follows from the list rather than from the dates: the
list is newest first, so the row further down is the older side. The cursor on
the mark itself shows that one commit, as it would with no mark at all. `<CR>`
works the same way, so a range can be opened a file at a time.

A merge at either end of a range is nothing special — a range compares two
trees, and only a commit shown on its own is compared with its first parent. What
does need saying is a range whose ends are on branches that diverged: the diff
then also undoes whatever the other branch did, and the winbar says
`(diverged; not one line of history)` rather than passing it off as a stretch of
history.

| key         | in the files pane | in the commits pane  | in the diff                   |
| ----------- | ----------------- | -------------------- | ----------------------------- |
| `<CR>`      | focus the diff    | look into the commit | jump to the source line       |
| `<BS>`      |                   | back out of it       |                               |
| `m`         |                   | mark, for a range    |                               |
| `gw`        | ignore whitespace | ignore whitespace    | ignore whitespace             |
| `s`         | stage the file    |                      | stage the line or selection   |
| `u`         | unstage the file  |                      | unstage the line or selection |
| `S` / `U`   |                   |                      | stage / unstage this hunk     |
| `]f` / `[f` |                   |                      | next / previous file          |
| `]h` / `[h` |                   |                      | next / previous hunk          |
| `o`         | edit the file     |                      |                               |
| `R`         | re-read           | re-read              |                               |
| `q`         | close             | close                | close                         |

There is one key per direction rather than one key toggling: a file changed in
the index and in the working tree both has no obvious sense in which it is
staged or not, and a row here states that state rather than hiding it.

Where the key is pressed decides what it acts on. In the list, `s` and `u` take
the whole file. In the diff they take the row under the cursor, or the rows a
visual selection covers, and `S` and `U` take the whole change the cursor is in.
Both panes are re-read from git afterwards.

Because the diff is a mixed view, the two directions are never ambiguous even
inside one hunk: `s` acts on the rows that are not staged yet and `u` on the
rows that are.

Binary files and changes with no lines to them, such as a pure rename, are
listed and say as much in place of a diff. Discarding changes and committing are
not implemented.

#### Ignoring whitespace

`gw`, from any of the three windows, stops lines that differ only in whitespace
from counting as changed. The winbar says `(whitespace ignored)` while it is on,
and a file whose only change is whitespace says so rather than claiming to have
no change at all. `gw` again puts it back.

While it is on, `s` and `u` **in the diff** refuse: a folded line is drawn as
context, taken from the index, so staging the rows on screen would write that
version back and leave the file still modified. `s` and `u` in the files pane are
unaffected — they run `git add`, which takes the file as it is.

The toggle belongs to `:UnidiffStatus`. The other commands honour the configured
value but have no key for it.

```lua
require('unidiff').setup({
  list_width = 30,          -- columns for the sidebar
  commit_count = 20,        -- how many recent commits it lists
  commit_ratio = 0.4,       -- share of the sidebar height the commit list takes
  ignore_whitespace = false, -- where every diff starts out
})
```

### Agreement with `git diff`

Hunk boundaries match `git diff`, because Neovim's `linematch` pass — which
disagrees with it — is left off. Turning it on buys word-level highlights on
hunks whose deleted and added blocks differ in size, at the cost of that
agreement:

```lua
require('unidiff').setup({ linematch = 60 })
```

Both sides of the trade-off are measured in
[docs/neovim-notes.md](docs/neovim-notes.md#linematch-disagrees-with-git).

### Highlight groups

`UnidiffAdd`, `UnidiffDelete`, `UnidiffAddText`, `UnidiffDeleteText`,
`UnidiffOldLnum`, `UnidiffNewLnum`, `UnidiffSeparator`, `UnidiffFileHeader`.

The mixed view adds `UnidiffStagedAdd`, `UnidiffStagedDelete`,
`UnidiffStagedAddText`, `UnidiffStagedDeleteText` and `UnidiffStagedSign`.

They default to background-only colors derived from `DiffAdd`/`DiffDelete`, are
defined the first time a diff is opened, and are redefined on `ColorScheme`.
Defining any of them yourself takes precedence. `setup()` is optional: it only
carries configuration, and the colors do not depend on it.

## Known limitations

- **No LSP semantic tokens.** The scratch buffers have no language server
  attached, so highlighting is purely syntactic.
- **Languages without a Tree-sitter parser need `:syntax` enabled.** They fall
  back to it, and a Tree-sitter-only setup gets no colors there. Highlighting
  them is also slower.
- **Word-level highlights need equal-sized blocks.** A replacement of 2 lines by
  3 falls back to line-level backgrounds only.
- **The winbar can be taken over by your config.** The file the cursor is in is
  reported through `'winbar'`, so a configuration or plugin that sets it for
  every window hides it. Every file still has its own header line in the buffer.
- **A merge conflict is listed but not shown.** The view it needs is not built
  yet, so an unmerged file says `(unresolved conflict)` in place of a diff and is
  listed as `UU` whichever pair git would print. `s` on the whole file resolves it
  the way `git add` does; everything else is refused, because it would discard the
  merge. See
  [docs/architecture.md](docs/architecture.md#a-merge-conflict-has-no-view).
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
