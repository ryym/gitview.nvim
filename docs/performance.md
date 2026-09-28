# Performance

## Cost model

Diffing is free. Everything expensive is either a subprocess or highlight
collection, and both scale with the number of files rather than the size of the
diff, which is why a many-file view was once slow while a single large file was
not.

One view over 60 changed files of ~360 lines each, showing 1440 rows:

| phase                                    | time         | share |
| ---------------------------------------- | ------------ | ----- |
| Enumerate changes (2 subprocesses)       | 14.4 ms      | 9%    |
| Read old versions (1 batched subprocess) | 11.2 ms      | 7%    |
| Read working files                       | 2.6 ms       | 2%    |
| `vim.diff`                               | 1.2 ms       | 1%    |
| Build the line list                      | 0.4 ms       | 0%    |
| Create ghost buffers                     | 5.2 ms       | 3%    |
| Collect highlights and set extmarks      | 111.8 ms     | 68%   |
| Dispose of ghost buffers                 | 0.6 ms       | 0%    |
| **total**                                | **163.6 ms** |       |

A commit has the same profile at a larger scale. One commit of 52 files, drawn
as 8300 rows into a configured diff window:

| phase                                         | time         | share |
| --------------------------------------------- | ------------ | ----- |
| Enumerate changes (2 subprocesses)            | 23 ms        | 5%    |
| Read both versions (1 batched subprocess)     | 19 ms        | 5%    |
| Read the message and stat (2 subprocesses)    | 13 ms        | 3%    |
| `vim.diff`, line list and ghost buffers       | 11 ms        | 3%    |
| Collect highlights (of which parsing: 109 ms) | 248 ms       | 59%   |
| Fill the buffer and set extmarks              | 106 ms       | 25%   |
| **total**                                     | **422 ms**   |       |

`vim.diff` accounts for a few percent at most. Anyone optimising this should
look at highlight collection first and subprocesses second.

## What made it fast

The working-tree view above took 1137 ms before three changes, none of which
altered the output:

| change                                                    | effect                      |
| --------------------------------------------------------- | --------------------------- |
| Query only the displayed rows                             | Rendering 741 ms → 112 ms   |
| Skip `filetype` when Tree-sitter can highlight            | Ghost buffers 159 ms → 6 ms |
| One `git cat-file --batch` instead of `git show` per file | Blob reads 221 ms → 11 ms   |

The commit above took 36 s, almost all of it inside `nvim_buf_set_lines`, until
the window options stopped reaching the view:

| change                                      | effect                                     |
| ------------------------------------------- | ------------------------------------------ |
| Keep module state off what `v:lua` converts | Drawing 36 s → 0.42 s, redraw 100 → 0.3 ms |

### Query only the displayed rows

A diff shows a few lines around each hunk, but the query used to run over the
whole tree. On a 363-line file a full captures pass costs 4.31 ms and yields 2537
captures, against 0.27 ms and 150 captures for the three ranges actually
displayed. The _parse_ still covers the whole buffer — that is what preserves
context — only the query is narrowed.

### Skip `filetype` when Tree-sitter can highlight

Assigning `'filetype'` fires `FileType`, which loads an ftplugin and a syntax
file for each of the two ghost buffers per file. None of it is used when
Tree-sitter does the highlighting, since `get_parser()` takes the language
explicitly.

### Batch the blob reads

A process spawn costs ~3.6 ms, so one `git show` per file dominated everything
else. `git cat-file --batch` takes every spec on stdin and answers in order.

### Keep module state off what `v:lua` converts

`'foldexpr'`, `'foldtext'`, `'statuscolumn'` and `'winbar'` call into the plugin
as `v:lua.require("unidiff.diff.render").fn()`. Evaluating that converts the
module table `require` returns into a Vim value on every call, following every
table it holds; the function being called does not have to touch any of it. The
cost of one call is therefore proportional to the data reachable from the
module, not to what the function does:

| module holds         | cost of one call |
| -------------------- | ---------------- |
| nothing              | 0.001 ms         |
| a 4000-entry table   | 0.82 ms          |
| a 16000-entry table  | 3.28 ms          |

When the views hung off the render module, this multiplied badly:

- `'foldexpr'` is evaluated once per line whenever the lines are replaced, so
  drawing a view cost O(rows²). 1513 rows took 1.8 s; 8300 rows took 36 s.
- `'statuscolumn'` is evaluated once per screen line on every redraw, so even
  moving the cursor in a large diff cost ~100 ms.

The views and the list states now live in file-local tables read through
`render.view_of()` and `list.state_of()`, and a test in each spec asserts that
neither module holds a table. Anything a window option can reach through
`require` has to stay small; new per-buffer state belongs in a local table.

## Measuring it again

Use `vim.uv.hrtime()` around each phase and print a breakdown; the phases above
correspond directly to the steps in [architecture.md](architecture.md). Three
things matter for a meaningful number:

- Use a repository with many files, not one large file. The two have very
  different profiles.
- Run with `--clean` plus the parser directory on the runtimepath, so a personal
  configuration is not being measured.
- Draw into a buffer shown in a window set up by `configure_window`, and include
  a `redraw` in the timing. Without the window options, whatever they cost is
  never paid and never measured.

To attribute a cost inside highlight collection, time `parser:parse()`,
`iter_captures()` and `nvim_buf_set_extmark()` separately. On a 363-line file
they came out at 0.81 ms, 4.31 ms and 0.98 ms respectively — parsing is cheap,
and the query dominates.

## If it needs to get faster

In rough order of value against effort:

- **Fill progressively.** Show the buffer at once and add highlights in
  `vim.schedule`d chunks, starting with the file under the cursor. Total time is
  unchanged, perceived time is not. The session's draw generation already tells
  a stale chunk to stop; the ghost buffers have to live until the last chunk
  has run.
- **Collect per file, lazily.** Building the buffer text is nearly free, so the
  buffer could be filled immediately and each file's highlights collected the
  first time it scrolls into view. Removes the ceiling entirely; costs a piece of
  state tracking what has been collected, and ghost buffers kept for the life of
  the view.
- **Start the subprocesses together.** A commit runs five one after another,
  but only the blob read depends on another's output. Starting the rest at once
  and waiting afterwards could save a few tens of milliseconds.
- **`nvim_set_decoration_provider()`.** The furthest version of lazy collection,
  but it needs the ghost buffers to stay alive for the life of the view.
