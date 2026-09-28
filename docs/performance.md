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

That total is not what the reader waits for. A view of more than 1000 rows is
shown before its highlights are collected, which leaves the commit above on
screen after ~120 ms and fully colored after ~370 ms; see
[Fill large views progressively](#fill-large-views-progressively).

## What made it fast

The working-tree view above took 1137 ms before three changes, none of which
altered the output:

| change                                                    | effect                      |
| --------------------------------------------------------- | --------------------------- |
| Query only the displayed rows                             | Rendering 741 ms → 112 ms   |
| Load no syntax file when Tree-sitter can highlight        | Ghost buffers 159 ms → 6 ms |
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

### Keep ghost buffers away from `FileType`

A ghost buffer never gets `'filetype'`. Tree-sitter needs nothing set, since
`get_parser()` takes the language explicitly. A language without a parser gets
`'syntax'` alone, which loads the syntax file the legacy path reads and nothing
else. `'filetype'` would also run ftplugins and every `FileType` autocommand of
the user's configuration, language servers included, for a buffer that lives a
moment.

What that cost, for a commit with eight scss files (sixteen ghost buffers) in a
real configuration:

| ghost buffers get           | per buffer | the commit's view |
| --------------------------- | ---------- | ----------------- |
| `'filetype'`                | ~40 ms     | 630 ms            |
| `'syntax'`                  | ~20 ms     | 345 ms            |
| nothing (`no_highlight`)    | —          | ~0 ms             |

Under `--clean` the same syntax file loads in ~3.5 ms. What the rest depends on
is the configuration, not the file:

- **Highlight groups.** Every `:hi` and `:syn` line a syntax file runs costs more
  the more groups are defined. With 3000 extra groups, scss took 10.4 ms instead
  of 3.6 ms; a configuration with a colorscheme, Tree-sitter and semantic tokens
  easily has that many.
- **`'runtimepath'`.** A syntax file that includes others runs `:runtime!`, which
  searches every entry. With 150 extra entries, scss took 7.0 ms.

A language without a parser therefore pays this once per ghost buffer, and a view
of many such files is slow however small they are. Installing the parser removes
the cost; `no_highlight` removes it along with the colors.

#### How the colors may differ

Loading the syntax file without the ftplugin can color some text differently
from the file's own buffer:

- A syntax file may depend on what an ftplugin sets, most likely `'iskeyword'`,
  which decides what `syn keyword` and `\k` count as a word.
- Syntax a user adds from a `FileType` autocommand is not applied. Additions in
  `after/syntax/` still are, since they load with the syntax file.

A comparison of `synID()` over every byte of a sample in 13 languages (perl, sh,
scss, css, make, ruby, python, javascript, html, yaml, lisp, clojure, vim) found
no difference under `--clean`, so this is a possibility rather than a known case.

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

### Fill large views progressively

A view of more than 1000 rows gets its text, diff colors and word highlights at
once, and its syntax afterwards: one file at a time, in steps of about 10 ms,
starting with the file the cursor is in and then those below it. The total is
unchanged; what changes is that the reader is not waiting on files that are not
on screen.

| commit rows | shown  | fully colored |
| ----------- | ------ | ------------- |
| 1513        | 52 ms  | 99 ms         |
| 8300        | 121 ms | 371 ms        |

Some details keep it correct:

- `render.draw` owns the ghost buffers from the moment it is called and frees
  them once the last file is filled. A step that finds the buffer showing
  another view frees them and stops, so a view replaced mid-fill never colors
  the rows of the one after it.
- Steps are chained with `vim.defer_fn(fn, 0)`, not `vim.schedule`. The event
  queue also runs whatever is scheduled while it is being drained, so chained
  `vim.schedule` calls ran back to back: the longest pause without a chance to
  take a keystroke was 250 ms against 40 ms with a timer.
- The screen is redrawn explicitly before the first step and after each one.
  Neovim puts off its own redraw while an event is already waiting, and the next
  step's timer always is, so without it the text showed up only with the last
  of the colors. A headless benchmark cannot see this: it has to call `redraw`
  itself to measure anything, which hides the problem.
- Small views stay synchronous. They are the ones redrawn constantly, such as a
  file being staged hunk by hunk, where colors arriving a moment late would
  flicker on every keystroke.

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

- **Fill the visible files synchronously.** A large view is shown uncolored for
  a moment. Filling the first file or two of the fill order before `draw`
  returns would put colors on screen with the text, for a few milliseconds more.
- **Collect per file, lazily.** Rather than filling every file in the
  background, collect each one only when it first scrolls into view. Saves the
  work for files never looked at; costs state tracking what has been collected,
  and ghost buffers kept for the life of the view.
- **Start the subprocesses together.** A commit runs five one after another,
  but only the blob read depends on another's output. Starting the rest at once
  and waiting afterwards could save a few tens of milliseconds.
- **`nvim_set_decoration_provider()`.** The furthest version of lazy collection,
  but it needs the ghost buffers to stay alive for the life of the view.
