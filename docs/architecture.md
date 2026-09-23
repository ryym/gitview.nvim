# Architecture

## Modules

The unified diff is one part of the plugin rather than the whole of it, so its
pipeline lives under `diff/` and the modules every part needs sit above it.

| module               | responsibility                                          |
| -------------------- | ------------------------------------------------------- |
| `init.lua`           | Commands and the public API                             |
| `config.lua`         | Defaults, and resolving a call's options against them   |
| `git.lua`            | Every subprocess call, and the parsers for their output |
| `util.lua`           | Messages shown to the user                              |
| `diff/source.lua`    | Reading the versions to compare, and their filetype     |
| `diff/view.lua`      | Assembling sources into a view, and freeing it           |
| `diff/lines.lua`     | `vim.diff` wrapper, unified line list, del/add pairing  |
| `diff/mixed.lua`     | Merging HEAD, index and working tree into one line list |
| `diff/highlight.lua` | Scratch buffers, and collecting highlight segments      |
| `diff/worddiff.lua`  | Word-level ranges within a pair of changed lines        |
| `diff/render.lua`    | Building the buffer, extmarks, gutter, winbar           |
| `diff/keymap.lua`    | What the keys do inside a diff buffer                   |

The dependency direction is one-way: `init` uses everything, `view` uses
`lines`, `mixed` and `highlight`, `render` uses `highlight`, `worddiff` and
`lines`, and `config`, `util` and `git` depend on nothing but Neovim.

`source` is the only part that reads git and the editor. It hands `view` plain
data, so assembling a view looks nothing up for itself.

## Pipeline

For each file in the diff:

1. **Read both versions.** The old side comes from git, the new side from the
   file's loaded buffer if it has one and from disk otherwise. git is only ever
   used to read blobs and to list what changed; the diff itself is `vim.diff`.
2. **Diff.** `lines.hunks()` returns raw hunk indices; `lines.build()` turns them
   into a flat list of context/deleted/added lines with both line numbers
   attached.
3. **Load ghost buffers.** Each whole version goes into its own scratch buffer,
   so the highlighter sees full context rather than a hunk fragment.

Then once for the whole view:

4. **Collect highlights** from the ghost buffers, for the displayed rows only.
   Tree-sitter is used when the language has a parser and legacy `:syntax`
   otherwise; both produce byte ranges paired with highlight groups, and nothing
   downstream knows which ran.
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
  the 1-based row of its header line
- `hunk_rows` — 1-based rows to jump between with `]h` / `[h`
- `rev`, `note` — shown in the winbar

Rows in `hunk_rows` and `files` are absolute in the combined buffer. Assembling
several files means concatenating each file's lines and shifting its rows by the
running offset.

### Line kinds

Every buffer row has a `unidiff.Line`, but only some of them stand for a line of
one of the two versions:

| kind                     | text                       | has line numbers |
| ------------------------ | -------------------------- | ---------------- |
| `context`, `add`, `del`  | source text                | yes              |
| `gap`                    | `···· N unchanged lines ····` | no            |
| `file`                   | the file's label           | no               |
| `blank`                  | empty, separates two files | no               |

`dlib.source_kinds` is the test for the first group. Anything that looks a line
up in a ghost buffer, prints a gutter, or jumps to the source has to check it
first, because the other kinds carry no `side`, `row` or `file`.

A `gap` is only emitted for two or more lines. It takes a row of its own, so
folding a single line away saves nothing and loses the line.

## Layering

Everything drawn is an extmark, ordered by priority:

| priority | layer                                        |
| -------- | -------------------------------------------- |
| 10       | Added/deleted line background, with `hl_eol` |
| 100      | Replayed syntax highlighting                 |
| 200      | Word-level change highlights                 |

The ordering is the point: the line background has to sit under the syntax
colors so they survive, and the word-level highlights have to sit over both so a
changed word stands out against its own line's background.

Separators and file headers are ordinary buffer lines, highlighted by the same
whole-line range marks as the diff colors. They were virtual lines once; making
them real means they can be searched, jumped to by row, and copied along with the
lines around them, and it removes the special cases that `virt_lines` above line
1 forced (see `neovim-notes.md`).

Two things are still deliberately _not_ buffer text:

- the gutter, drawn with `'statuscolumn'`, so line numbers stay out of a yank
- the name of the file the cursor is in, drawn in the `'winbar'`

The winbar is recomputed on redraw rather than set once, so it follows the cursor
through a multi-file view and keeps naming the file after its header line has
scrolled off.

## Mixed view

`:UnidiffMixed` (`init.open_mixed`) replaces step 2 of the pipeline with
`mixed.build`, which takes three versions of each file instead of two. The rest
of the pipeline is unchanged apart from a third ghost buffer for the index.

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

A file appears when `git diff --cached` or `git diff` lists it, joined on the
index path. A file with only staged changes has a working tree equal to its
index, and one with only unstaged changes has a HEAD equal to its index, so
neither is read twice.

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

## Known gaps

`change_pairs()` matches deleted lines to added ones by position, so a block
replaced by one of a different size gets no word-level highlights at all.
Matching them by similarity instead would lift that, and unlike enabling
`linematch` it would not move any hunk boundary: which lines are compared for
word highlights is independent of how the diff is laid out.
