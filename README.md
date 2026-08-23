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
replayed onto the diff buffer as extmarks. Line numbers, `+`/`-` markers, file
headers and separators are all decoration rather than text, so yanking a
selection gives you code.

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
- **A skipped range at the very top has no separator line.** That count is
  reported in the winbar instead.
- **Word-level highlights need equal-sized blocks.** A replacement of 2 lines by
  3 falls back to line-level backgrounds only.
- **The winbar can be taken over by your config.** The file the cursor is in is
  reported through `'winbar'`, so a configuration or plugin that sets it for
  every window may hide the name of the first file. The other files keep their
  inline headers.
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
