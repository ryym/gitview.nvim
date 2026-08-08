# unidiff.nvim

A GitHub-style unified diff view for Neovim: deleted and added lines in one
column, both syntax highlighted, and the buffer is still just text you can
select, yank and search.

Requires Neovim 0.12+ and a Tree-sitter parser for the language you are viewing.

## Usage

```vim
:Unidiff          " diff the current buffer against HEAD
:Unidiff HEAD~3   " ...or against any revision
```

```lua
require('unidiff').setup()
require('unidiff').open({ rev = 'main', context = 5 })
```

Inside the diff buffer:

| key    | action              |
| ------ | ------------------- |
| `]h`   | next hunk           |
| `[h`   | previous hunk       |
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

### Highlight groups

`UnidiffAdd`, `UnidiffDelete`, `UnidiffAddText`, `UnidiffDeleteText`,
`UnidiffOldLnum`, `UnidiffNewLnum`, `UnidiffSeparator`.

They default to background-only colors derived from `DiffAdd`/`DiffDelete`, and
are redefined on `ColorScheme`. Defining any of them yourself takes precedence.

## Known limitations

- **No LSP semantic tokens.** The scratch buffers have no language server
  attached, so highlighting is purely syntactic.
- **A skipped range at the very top has no separator line.** Neovim does not
  render `virt_lines_above` on the first buffer line, so that count is reported
  in the winbar instead.
- **Word-level highlights need equal-sized blocks.** A replacement of 2 lines by
  3 falls back to line-level backgrounds only.
- **Everything is computed eagerly** when the diff opens. That is ~50 ms for a
  1500-line file with 80 hunks; very large files would want
  `nvim_set_decoration_provider()` instead.
- Only text diffs. Renames, binary files and mode changes are not shown.

## Tests

```sh
make test
```
