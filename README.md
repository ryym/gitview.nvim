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

The hard part is that a diff buffer interleaves two different versions of a
file, so its text is not valid source in any language — a Tree-sitter parser
attached to it would produce garbage.

Instead:

1. `vim.diff(..., { result_type = 'indices' })` produces line-level hunks.
2. The old and new versions are each loaded **whole** into a scratch buffer and
   parsed there, so the highlighter sees full context. A line deleted from the
   middle of a multi-line string is highlighted as a string, which is impossible
   to get right from the hunk fragment alone.
3. The unified buffer is filled with nothing but source text, and the collected
   highlights are replayed onto it as extmarks.
4. Diff backgrounds, word-level highlights and the line-number gutter are layered
   on top as decoration only.

Step 2 uses Tree-sitter when the language has a parser, otherwise it probes
legacy `:syntax` with `synID()`. Either way the result is a set of byte ranges
and highlight groups, and the rest of the pipeline does not care which produced
them.

Both are restricted to the rows the diff actually displays. The *parse* still
covers the whole file, which is what makes a deleted line inside a multi-line
string come out as a string, but querying the rest of the tree would only
produce captures for rows nobody sees.

Because the buffer holds only source text and the gutter is drawn through
`'statuscolumn'`, yanking a selection gives you code — no `+`/`-` markers and no
line numbers.

### Layering

Everything is extmarks, ordered by priority:

| priority | layer                                    |
| -------- | ---------------------------------------- |
| 10       | added/deleted line background (`hl_eol`) |
| 100      | replayed syntax highlighting             |
| 200      | word-level change highlights             |

### Several files in one buffer

`:UnidiffAll` enumerates changes with `git diff --name-status` and lays every
file's diff out end to end in a single buffer. Each file is highlighted with its
own language, and the buffer still holds nothing but source text: file headers
are virtual lines, and the winbar names whichever file the cursor is in.

- The new side is a **loaded buffer's contents** when the file is open, and the
  file on disk otherwise, so unsaved edits show up.
- Added, deleted and renamed files are all handled.
- Binary files, and changes with no textual difference such as a pure rename,
  have no lines to show. They are counted in the winbar rather than dropped
  silently.

### Agreement with `git diff`

The diff itself is computed by `vim.diff()`; git is only used to read the old
blob. Hunk boundaries still match `git diff` because `linematch` is left off.

`linematch` is a Neovim-only pass that re-pairs lines inside a hunk and splits
the hunk accordingly. Turning it on makes `a b c d e` → `a b X Y d e` render as
`+X` `-c` `+Y` where git shows `-c` `+X` `+Y`. In exchange it lets word-level
highlights appear on hunks whose deleted and added blocks differ in size, which
they otherwise cannot:

```lua
require('unidiff').setup({ linematch = 60 })
```

### Highlight groups

`UnidiffAdd`, `UnidiffDelete`, `UnidiffAddText`, `UnidiffDeleteText`,
`UnidiffOldLnum`, `UnidiffNewLnum`, `UnidiffSeparator`.

They default to background-only colors derived from `DiffAdd`/`DiffDelete`, and
are redefined on `ColorScheme`. Defining any of them yourself takes precedence.

## Known limitations

- **No LSP semantic tokens.** The scratch buffers have no language server
  attached, so highlighting is purely syntactic.
- **Languages without a Tree-sitter parser cost more.** The legacy `:syntax`
  fallback has no bulk query and has to probe byte by byte, so it runs roughly
  4x slower than the Tree-sitter pass. Only the lines the diff actually shows
  are probed, which keeps it proportional to the size of the diff. It also needs
  `:syntax` to be enabled; a Tree-sitter-only setup gets no colors there.
- **A skipped range at the very top has no separator line.** Neovim does not
  render `virt_lines_above` on the first buffer line, so that count is reported
  in the winbar instead.
- **Word-level highlights need equal-sized blocks.** A replacement of 2 lines by
  3 falls back to line-level backgrounds only, because deleted and added lines
  are paired by position. Pairing them by similarity instead would lift this
  without affecting hunk boundaries.
- **The winbar can be taken over by your config.** The file the cursor is in is
  reported through `'winbar'`, so a configuration or plugin that sets it for
  every window may overwrite it and hide the name of the first file. The other
  files keep their inline headers.
- **Everything is computed eagerly** when the diff opens, and grows linearly
  with the number of files: ~165 ms for 60 files of ~360 lines each. A very
  large diff would want per-file lazy collection or
  `nvim_set_decoration_provider()` instead.

## Tests

```sh
make test
```
