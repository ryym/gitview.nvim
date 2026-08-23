# Architecture

## Modules

| module | responsibility |
| --- | --- |
| `init.lua` | Commands, configuration, assembling views, keymaps |
| `git.lua` | Every subprocess call, and the parsers for their output |
| `diff.lua` | `vim.diff` wrapper, unified line list, del/add pairing |
| `highlight.lua` | Scratch buffers, and collecting highlight segments |
| `worddiff.lua` | Word-level ranges within a pair of changed lines |
| `render.lua` | Building the buffer, extmarks, gutter, winbar |

The dependency direction is one-way: `init` uses everything, `render` uses
`highlight`, `worddiff` and `diff`, and the rest depend on nothing but Neovim.

## Pipeline

For each file in the diff:

1. **Read both versions.** The old side comes from git, the new side from the
   file's loaded buffer if it has one and from disk otherwise.
2. **Diff.** `diff.hunks()` returns raw hunk indices; `diff.build()` turns them
   into a flat list of context/deleted/added lines with both line numbers
   attached.
3. **Load ghost buffers.** Each whole version goes into its own scratch buffer,
   so the highlighter sees full context rather than a hunk fragment.

Then once for the whole view:

4. **Collect highlights** from the ghost buffers, for the displayed rows only.
5. **Render**: write the source text, replay the highlights as extmarks, and
   layer diff backgrounds, word-level highlights, headers and separators on top.
6. **Discard the ghost buffers.** They exist only for step 4.

Step 3 is what makes a line deleted from the middle of a multi-line string come
out as a string: the fragment alone carries no such information.

## Data shapes

### `unidiff.Line`

One row of the rendered buffer.

- `text` — the source line, exactly as it appears in the buffer
- `kind` — `context`, `add` or `del`
- `old_lnum` / `new_lnum` — line numbers in each version; `nil` on the side
  where the line does not exist
- `side` — which version `text` came from, `old` or `new`
- `row` — 0-based row of `text` in that version's ghost buffer
- `file` — index into `View.files`

`side` plus `row` plus `file` is what links a rendered row back to the ghost
buffer its highlights come from. `old_lnum` / `new_lnum` are for display and for
jumping to the source; they are not used for highlighting.

### `unidiff.View`

Everything one diff buffer needs, stored in `render.views[bufnr]` and dropped on
`BufWipeout`.

- `lines` — the `unidiff.Line[]`, one per buffer row
- `files` — `unidiff.File[]`, each with its ghost buffers, language, label, and
  the 1-based row where it starts
- `hunk_rows` — 1-based rows to jump between with `]h` / `[h`
- `gaps` — skipped unchanged ranges: the row a separator belongs above, and how
  many lines were skipped
- `rev`, `note` — shown in the winbar

Rows in `hunk_rows` and `gaps` are absolute in the combined buffer. Assembling
several files means concatenating each file's lines and shifting its rows by the
running offset.

## Layering

Everything drawn is an extmark, ordered by priority:

| priority | layer |
| --- | --- |
| 10 | Added/deleted line background, with `hl_eol` |
| 100 | Replayed syntax highlighting |
| 200 | Word-level change highlights |

The ordering is the point: the line background has to sit under the syntax
colors so they survive, and the word-level highlights have to sit over both so a
changed word stands out against its own line's background.

Two layers are deliberately *not* extmark-based, because they must not become
buffer text:

- the gutter, drawn with `'statuscolumn'`
- file headers and gap separators, drawn as `virt_lines`

## Invariants

Each of these is guarded by a test. Breaking one is a regression even if
everything still looks right.

| invariant | guarded by |
| --- | --- |
| Buffer text equals source text, row for row | `render_spec`, `multifile_spec` |
| Hunk boundaries match `git diff` | `diff_spec` |
| No line is emitted twice, and line numbers only increase | `diff_spec` |
| Highlight ranges stay inside their line and on character boundaries | `render_spec`, `worddiff_spec`, `highlight_spec` |
| Restricting collection to some rows does not change what those rows get | `highlight_spec` |
| Colors work without `setup()` ever being called | `render_spec` |
| Word-level pairing never crosses a file boundary | `diff_spec` |

## Deliberate omissions

Alternatives that were tried or considered and rejected, so they are not
re-attempted by accident:

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
