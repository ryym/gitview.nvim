# Neovim and git behaviours this code relies on

Every entry here was established by measurement against Neovim 0.12 and git 2.55,
usually after the obvious approach failed quietly. They are collected in one
place because none of them are guessable from the documentation, and code that
looks like an obvious simplification will silently re-break several of them.

## Highlighting

### `vim.inspect_pos()` cannot collect highlights affordably

It returns the full highlight stack at one position — Tree-sitter, `:syntax`,
semantic tokens and extmarks — which is far more than replaying syntax needs, and
its Tree-sitter entries **carry no end column**. Without one there is no way to
skip to the end of a capture, so every byte has to be probed.

Measured on a 1590-line Lua file:

| approach                                     | time    |
| -------------------------------------------- | ------- |
| `vim.inspect_pos()` per byte, 300 lines only | 393 ms  |
| `query:iter_captures()` over all 1590 lines  | 15.5 ms |

Use `vim.treesitter.query.get(lang, 'highlights')` and iterate. For legacy
`:syntax`, where no bulk query exists, use `vim.fn.synID()` rather than
`inspect_pos`: 384 lines cost 24.6 ms that way.

### An unrendered buffer is never parsed

`vim.treesitter.start()` followed by `vim.wait(0)` leaves `inspect_pos` and the
query API returning nothing. Ghost buffers are never displayed, so nothing
triggers a parse. Call `parser:parse(true)` explicitly.

### Restricting a query to a row range is safe

`query:iter_captures(node, buf, start, stop)` takes an exclusive `stop`, and it
**still reports a capture that began before `start`**. A row 30 lines inside a
multi-line string returns that string's capture when queried alone. This is what
lets collection be limited to the displayed rows without losing context.

Build the ranges disjoint. A capture spanning two overlapping ranges would
otherwise be emitted twice for the same row.

### `@capture.lang` groups look undefined but are not

`nvim_get_hl(0, { name = '@string.lua' })` returns an empty table, while
`nvim_get_hl(0, { id = nvim_get_hl_id_by_name('@string.lua'), link = false })`
resolves to `String`'s attributes. Passing the name to an extmark works.

### Legacy `:syntax` needs the buffer to be current, but not visible

`vim.fn.synID()` only reads the current buffer, so it has to run inside
`nvim_buf_call`. Vim computes syntax state from the preceding lines on demand,
so probing a subset of rows is still context-correct: a line 30 deep inside a
POD block resolves to `perlPOD` without its opener ever being probed.

Prefer the syntax item's own group name over `synIDtrans()`'s resolved one. Both
render identically, but extmarks follow `:hi link` chains at draw time, so the
unresolved name keeps up if the colorscheme changes while the diff is open.

### `vim.treesitter.language.add()` reports failure as `nil`

Not `false`. A check like `added ~= false` treats every missing parser as
present. Compare against `true`.

## Extmarks and drawing

### `line_hl_group` ignores extmark priority

It is painted outside the priority order, so a higher-priority inline `hl_group`
on the same line does not show through it at all. A whole-line background that
other marks must be able to override has to be a range mark instead:

```lua
{ end_row = row + 1, end_col = 0, hl_group = ..., hl_eol = true }
```

`end_row` may be one past the last line. Ending on the same row with
`end_col = #text` does _not_ fill the rest of the screen line, even with
`hl_eol`.

### `virt_lines_above` does not render on the first line

Virtual lines placed above buffer line 1 are simply not drawn, so nothing can be
shown above the top of the buffer that way. This is one reason file headers here
are ordinary buffer lines: the first file's header has nowhere to hang
otherwise.

### `'foldexpr'` is evaluated while the lines are being replaced

`nvim_buf_set_lines` recomputes expression folds before it returns, in every
window showing the buffer, not at the next redraw. Whatever the expression reads
has to describe the new lines before they are written; set afterwards, the folds
describe the old ones until something else changes the buffer. The expression is
evaluated with the window being folded made current, so it can find its buffer
with `nvim_get_current_buf()` even when another window has focus.

Evaluating it also sets `v:lnum`, so anything that reads `v:lnum` afterwards —
a `'statuscolumn'` expression called by hand, say — has to set it again first.

### Replacing the lines under a fold does not keep it open or closed

After `nvim_buf_set_lines` replaces every line, an expression fold that was open
stays open if the new fold is at least as long, and comes back closed if it is
shorter. A fold appearing where there was none follows `'foldlevel'`. Keeping
what the reader chose means reading `foldclosed()` before the replacement and
applying `:foldopen` or `:foldclose` after it.

### A list returned by `'foldtext'` is drawn over `Folded`

Each chunk's group is combined with `Folded` rather than replacing it, so a chunk
of a syntax group keeps the fold's background and takes only the colors the group
sets. Naming `Folded` in the chunk as well is not needed.

### `'statuscolumn'` is evaluated for every screen line

Return blanks when `vim.v.virtnum ~= 0`, or a wrapped line repeats the numbers of
the buffer line it continues.

### Colorscheme diff groups carry a foreground

`DiffAdd` and `DiffDelete` usually set `fg` as well as `bg`. Using them directly
for the line background repaints every character and erases the syntax colors
just replayed. Take `bg` only.

### `:colorscheme` clears attribute groups but not `default link`s

A group defined with `nvim_set_hl(0, name, { bg = ..., default = true })` is gone
after a colorscheme change and must be redefined; one defined as a `default link`
survives. This is why the `ColorScheme` hook exists, and why a test that clears
groups by hand behaves differently from a real colorscheme change.

Note also that `default = true` will not overwrite a group that already exists,
even an empty one.

## Diffing

### A zero-count side points at the _preceding_ line

`vim.diff(..., { result_type = 'indices' })` returns
`{old_start, old_count, new_start, new_count}`. When a count is 0, that side's
`start` is the line _before_ which the change applies, so the first affected line
is `start + 1`:

```
a b c   ->  a Z b c    {1, 0, 2, 1}
a b c   ->  a c        {2, 1, 1, 0}
```

Treating `start` as the first affected line shifts every context calculation by
one.

### `linematch` disagrees with git

It is a Neovim-only pass that re-pairs lines inside a hunk and splits the hunk
accordingly. With it off, `vim.diff` matches `git diff` on hunk boundaries;
checked across single-line changes, 1-to-2 and 3-to-1 replacements, block inserts
with duplicated tails, indentation-sensitive inserts, reorders and scattered
edits over a long file. With it on, `a b c d e` → `a b X Y d e` becomes two hunks
where git reports one.

The diff algorithm was not the source of disagreement: `histogram`, `myers` and
`indent_heuristic` all matched git on those cases.

## Lua and git

### LuaJIT has no `utf8` library

`_G.utf8` is `nil`. Split on character boundaries with
`vim.fn.split(s, '\\zs')`.

### `git cat-file --batch` must be read raw

Each object is a header line `<sha> <type> <size>`, then exactly `size` bytes,
then a newline; an unresolvable spec yields `<spec> missing`. Reading it with
`text = true` rewrites CRLF and desynchronises the stream from those byte counts.
Results come back in request order, so match them by position rather than parsing
the spec back out of the header.

`<rev>:` with an empty path resolves to the root tree rather than reporting
itself missing, so files that have no old version must be left out of the
request.

### `-z` output shapes differ per subcommand

- `git diff --name-status -z` emits `M<NUL>path`, but renames and copies as
  `R100<NUL>old<NUL>new` — three records, not two.
- `git diff --numstat -z` emits `added<TAB>deleted<TAB>path`, with `-` for both
  counts when the file is binary, and leaves the path field _empty_ for a rename,
  following it with the old and new paths as separate records.

### An empty blob is not one empty line

`vim.split('', '\n')` returns `{ '' }`. A file with no content has no lines at
all, and treating it as one empty line puts a phantom line in the diff.
