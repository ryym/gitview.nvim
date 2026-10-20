# Testing

```sh
make test
```

Performance is not tested here: `make bench` measures it, and nothing fails on
a slowdown. See [performance.md](performance.md#the-benchmark).

## How it runs

`tests/run.lua` is executed by a headless Neovim (`nvim --headless --clean -l`).
It puts `test()` and `eq()` in the global table, then `dofile`s every
`tests/*_spec.lua`. There is no external framework to install, and specs are
plain Lua files.

`eq(expected, actual, message)` compares with `vim.deep_equal` and prints both
sides on failure. Use `assert()` for anything else.

A failing run exits non-zero, so `make test` fails the way a build should.

## Writing a spec

Test behaviour that would be silently wrong, not behaviour the type checker would
catch. Most of the suite exists because something was measured and turned out to
work differently than expected; a spec is how that stays fixed. When a test
encodes a Neovim behaviour, say which one in a comment — the assertion alone does
not explain why it is worth asserting.

Fixtures that need a language use `lua` when Tree-sitter should handle it and
`perl` when the legacy `:syntax` path should, since Neovim bundles a Lua parser
and no Perl one. Specs that touch the legacy path call `vim.cmd('syntax enable')`
first.

## Environment traps

These bite when writing throwaway scripts to reproduce something, more than in
the suite itself.

- **`-u <file>` skips filetype detection.** With `--clean -u script.lua`,
  `defaults.vim` is not sourced, so an edited file has no `filetype` and no
  highlights are collected. Add `vim.cmd('filetype plugin indent on')`.
- **`-u <file>` runs before `plugin/`.** User commands are not defined yet inside
  that file. Use `--cmd 'set rtp+=...'` and `-c 'luafile ...'`, or call the Lua
  API directly.
- **`--clean` drops personal parser directories.** Add the parser directory to
  the runtimepath explicitly if a spec needs a parser Neovim does not bundle.
- **Relative runtimepath entries break after `:lcd`.** Use an absolute path.

## Checking every commit

Tests are expected to pass at each commit, not only at the tip. A throwaway
worktree makes that cheap to verify:

```sh
git worktree add -q --detach /tmp/wt HEAD
for sha in $(git rev-list --reverse <base>..HEAD); do
  git -C /tmp/wt checkout -q --detach "$sha"
  (cd /tmp/wt && make test | tail -1)
done
git worktree remove --force /tmp/wt
```
