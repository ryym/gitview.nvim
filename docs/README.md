# Developer documentation

Notes for working on unidiff.nvim. [The main README](../README.md) covers
installation, commands and configuration; nothing here is repeated there.

| document | what it covers |
| --- | --- |
| [architecture.md](architecture.md) | The pipeline, the modules, the data shapes, and the invariants |
| [neovim-notes.md](neovim-notes.md) | Neovim and git behaviours the code depends on, and why the obvious alternatives were rejected |
| [performance.md](performance.md) | Where the time goes, measured, and how to measure it again |
| [testing.md](testing.md) | How the suite runs and how to add to it |

## Read this first

Two things explain most of the design.

**The diff buffer is not valid source code.** It interleaves two versions of a
file, so no parser can highlight it directly. Highlights are collected from
separate scratch buffers holding each whole version, then replayed as extmarks.

**The buffer text is the source text and nothing else.** Line numbers, `+`/`-`
markers, file headers and gap separators are all decoration, so a visual
selection yanks code. Anything that would put non-source characters into the
buffer breaks a documented promise.
