# Performance

## Cost model

Diffing is free. Everything expensive is either a subprocess or highlight
collection, and both scale with the number of files rather than the size of the
diff, which is why a many-file view was once slow while a single large file was
not.

`:UnidiffAll` over 60 files of ~360 lines each, showing 1440 rows:

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

`vim.diff` accounts for well under 1% of it. Anyone optimising this should look
at highlight collection first and subprocesses second.

## What made it fast

The same view took 1137 ms before three changes, none of which altered the
output:

| change                                                    | effect                      |
| --------------------------------------------------------- | --------------------------- |
| Query only the displayed rows                             | Rendering 741 ms → 112 ms   |
| Skip `filetype` when Tree-sitter can highlight            | Ghost buffers 159 ms → 6 ms |
| One `git cat-file --batch` instead of `git show` per file | Blob reads 221 ms → 11 ms   |

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

## Measuring it again

Use `vim.uv.hrtime()` around each phase and print a breakdown; the phases above
correspond directly to the steps in [architecture.md](architecture.md). Two
things matter for a meaningful number:

- Use a repository with many files, not one large file. The two have very
  different profiles.
- Run with `--clean` plus the parser directory on the runtimepath, so a personal
  configuration is not being measured.

To attribute a cost inside highlight collection, time `parser:parse()`,
`iter_captures()` and `nvim_buf_set_extmark()` separately. On a 363-line file
they came out at 0.81 ms, 4.31 ms and 0.98 ms respectively — parsing is cheap,
and the query dominates.

## If it needs to get faster

In rough order of value against effort:

- **Collect per file, lazily.** Building the buffer text is nearly free, so the
  buffer could be filled immediately and each file's highlights collected the
  first time it scrolls into view. Removes the ceiling entirely; costs a piece of
  state tracking what has been collected.
- **Fill progressively.** Show the buffer at once and add highlights in
  `vim.schedule`d chunks. Total time is unchanged, perceived time is not.
- **`nvim_set_decoration_provider()`.** The furthest version of lazy collection,
  but it needs the ghost buffers to stay alive for the life of the view.
