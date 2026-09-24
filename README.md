# unidiff.nvim

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

:UnidiffStatus    " work in progress: list every uncommitted change
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

### The file list (work in progress)

`:UnidiffStatus` opens a tab with every uncommitted change listed on the left
and the selected file's diff on the right. Moving the cursor in the list draws
the file it lands on.

The list has one row per file, with the two status letters `git status --short`
prints. A file changed both in the index and in the working tree is still one
row, and its diff is the mixed view above: what is staged and what is not, at
once. Only the letters are drawn; the row itself is the path, so yanking one
gives something pasteable.

| key       | in the list                       | in the diff                 |
| --------- | --------------------------------- | --------------------------- |
| `<CR>`    | focus the diff                    | jump to the source line     |
| `s`       | stage the file under the cursor   | stage the line or selection |
| `u`       | unstage the file under the cursor | unstage the line or selection |
| `S` / `U` |                                   | stage / unstage this hunk   |
| `]f`      |                                   | next file                   |
| `[f`      |                                   | previous file               |
| `]h`      |                                   | next hunk                   |
| `[h`      |                                   | previous hunk               |
| `o`       | edit the file under the cursor    |                             |
| `R`       | re-read the repository            |                             |
| `q`       | close                             | close                       |

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

```lua
require('unidiff').setup({ list_width = 30 })
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
| [docs/performance.md](docs/performance.md) | Where the time goes, measured, and how to measure it again |
| [docs/testing.md](docs/testing.md) | How the suite runs and how to add to it |
