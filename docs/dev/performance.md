# Performance

For anyone changing what a view costs: where the time goes, the rules that keep it fast, and
how to measure it. The numbers show proportions, and were taken on one machine.

## Cost model

Diffing is free. Everything expensive is either a subprocess or highlight collection, and both
scale with the number of files rather than the size of the diff. Anyone optimising this should
look at highlight collection first and subprocesses second.

One commit of 52 files, drawn as 8300 open rows into a configured diff window:

| phase                                         | time       | share |
| --------------------------------------------- | ---------- | ----- |
| Enumerate changes (2 subprocesses)            | 23 ms      | 5%    |
| Read both versions (1 batched subprocess)     | 19 ms      | 5%    |
| Read the message and stat (2 subprocesses)    | 13 ms      | 3%    |
| `vim.diff`, line list and scratch buffers     | 11 ms      | 3%    |
| Collect highlights (of which parsing: 109 ms) | 248 ms     | 59%   |
| Fill the buffer and set extmarks              | 106 ms     | 25%   |
| **total**                                     | **422 ms** |       |

A process spawn costs ~3.6 ms, which is why versions are read in one batched subprocess rather
than one per file.

### Folded rows

Every unchanged line is in the buffer, folded, so a view's row count follows the size of its files
rather than of its diff. One 50,000-line Lua file with one line changed, in a configured window:

| phase                                  | folded  | only open rows |
| -------------------------------------- | ------- | -------------- |
| Draw, open rows colored                | 430 ms  | 267 ms         |
| of which `'foldexpr'`                  | ~170 ms | —              |
| Folded rows colored, in the background | 1.3 s   | —              |

`'foldexpr'` is the one cost paid on every draw. Most of the rest of the 267 ms is parsing the two
versions, which happens whether or not the unchanged lines are in the buffer.

## Rules that keep it fast

### Query only the rows shown

The parse covers the whole buffer, which is what preserves context, but only the rows displayed are
queried. On a 363-line file a full captures pass costs 4.31 ms against 0.27 ms for the three ranges
shown.

### Keep scratch buffers away from `FileType`

A scratch buffer never gets `'filetype'`, which would run ftplugins and every `FileType` autocommand
of the user's configuration, language servers included. A language with no parser gets `'syntax'`
alone. What that costs follows the configuration rather than the file: every `:hi` and `:syn` line
costs more the more groups are defined, and a syntax file including others searches every
`'runtimepath'` entry. A commit with eight scss files in a real configuration:

| scratch buffers get                | per buffer | the commit's view |
| ---------------------------------- | ---------- | ----------------- |
| `'filetype'`                       | ~40 ms     | 630 ms            |
| `'syntax'`                         | ~20 ms     | 345 ms            |
| nothing (`no_highlight_filetypes`) | —          | ~0 ms             |

Loading the syntax file without the ftplugin could color some text differently from the file's own
buffer: a syntax file may depend on an ftplugin's `'iskeyword'`, and syntax added from a `FileType`
autocommand is not applied. Comparing `synID()` over every byte of a sample in 13 languages found no
difference under `--clean`, so this is a possibility rather than a known case.

### Keep module state off what `v:lua` converts

`'foldexpr'`, `'foldtext'`, `'statuscolumn'` and `'winbar'` call into the plugin through `v:lua`.
Evaluating that converts the module table `require` returns into a Vim value on every call, following
every table it holds. The cost of one call is proportional to the data reachable from the module, not
to what the function does:

| module holds        | cost of one call |
| ------------------- | ---------------- |
| nothing             | 0.001 ms         |
| a 4000-entry table  | 0.82 ms          |
| a 16000-entry table | 3.28 ms          |

`'foldexpr'` runs once per line, so a large table there makes drawing a view quadratic in its rows.
Anything a window option can reach through `require` has to stay small, and new per-buffer state
belongs in a local table.

### Leave long lines uncolored

Collecting a line's syntax costs per capture, and for a very long line Tree-sitter's captures pass grows
faster than the line does. One changed line of ~400 KB of JavaScript took 6.7 s to draw before lines
past `'synmaxcol'` were left out of collecting, parsing and word diffing, and takes 2 ms now. The whole
line goes uncolored, since the query is restricted by row and the part before the limit would cost
nearly what the whole line does.

A line just under the limit still costs in full: 200 lines of ~2.8 KB take 3.3 s, and are not filled
progressively, since that is decided by rows.

### Fill large views progressively

A view of more than 1000 open rows gets its text, diff colors and word highlights at once, and their
syntax afterwards, starting with the file the cursor is in. The total is unchanged, but the reader is
not waiting on files that are not on screen.

| open rows | shown  | fully colored |
| --------- | ------ | ------------- |
| 1513      | 52 ms  | 99 ms         |
| 8300      | 121 ms | 371 ms        |

Small views stay synchronous. They are the ones redrawn constantly, such as a file being staged hunk by
hunk, where colors arriving a moment late would flicker on every keystroke.

## Measuring it

### The benchmark

```sh
make bench
make bench SCENARIOS='file_huge switch_from_huge'
```

`make bench` times a fixed set of scenarios and compares each number with the last few runs on the same
machine. It is for watching the numbers drift and for comparing before and after a change; nothing fails
on a slowdown.

```
scenario               metric        median   baseline   change
file_rewrite           full_ms        366.8      381.3      -4%
                       move_ms          0.5        0.6      -2%
                       page_ms          3.0        2.8      +7%
                       shown_ms        68.7       71.2      -4%
```

- **A scenario is a repository and what a user does in it.** Nothing reaches into the plugin's modules, so
  a scenario survives a change to how a view is built. They are listed in `bench/scenarios.lua`.
- **`shown_ms` and `full_ms`.** From the key to the view being on screen, and to nothing being left to do.
- **Each sample is a Neovim of its own**, under `--clean`, so that a sample does not inherit another's
  caches. `BENCH_N` sets how many are taken, and the median is reported.
- **The history is `.local/bench/history.jsonl`**, never committed, since the numbers belong to the machine.
  A metric 20% or more over the median of the last five runs is marked `!`.
- **Scaling** is reported for scenarios that differ only in size. A cost growing with the square of the size
  shows in the ratio, which is the same on any machine.

Lua covers the Tree-sitter path and scss the legacy one, and the report warns if a sample took the other. A
scenario needing a parser Neovim does not bundle is skipped without it; `BENCH_RTP` adds runtimepath entries,
comma-separated:

```sh
BENCH_RTP=~/.local/share/nvim/site make bench SCENARIOS=json_lock
```

A full run takes about 40 s. The numbers vary by 10% or so between runs on an idle machine, more on battery or
under load.

### The timing log

The steps a reader waits on are timed all the time, and written to `stdpath('log')/gitview-perf.log` when either
of these is set:

- `vim.g.gitview_perf`, which can be set in a running session with `:let g:gitview_perf = 1`
- `GITVIEW_PERF` in the environment, other than `0`

Watching the log with `tail -f` while moving through the lists shows where a delay comes from. A line is written
when its step ends, so a step comes after the ones inside it.

```
21:51:50.151 git 21.0ms cmd=diff --name-status
21:51:50.175 source 45.5ms
21:51:50.176 build 1.3ms
21:51:50.194 detail 17.4ms
21:51:50.225 draw 30.9ms rows=1129
21:51:50.225 select 95.6ms gen=6 kind=commit
21:51:50.240 syntax.background 16.1ms jobs=2 steps=2
```

### Measuring a phase precisely

For a breakdown finer than the log, use `vim.uv.hrtime()` around each phase. Three things matter for a meaningful
number:

- Use a repository with many files, not one large file. The two have very different profiles.
- Run with `--clean` plus the parser directory on the runtimepath, so a personal configuration is not measured.
- Draw into a buffer shown in a configured window, and include a `redraw` in the timing. Without the window
  options, whatever they cost is never paid and never measured.

A headless benchmark has to call `redraw` itself to measure anything, which hides a missing redraw from it.
