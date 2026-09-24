# Developer documentation

Notes for working on unidiff.nvim. [The main README](../README.md) covers
installation, commands and configuration; nothing here is repeated there.

| document                           | what it covers                                                                                |
| ---------------------------------- | --------------------------------------------------------------------------------------------- |
| [architecture.md](architecture.md) | The pipeline, the modules, the data shapes, and the invariants                                |
| [neovim-notes.md](neovim-notes.md) | Neovim and git behaviours the code depends on, and why the obvious alternatives were rejected |
| [staging.md](staging.md)           | How the index is written, why not with a patch, and where that has holes                      |
| [performance.md](performance.md)   | Where the time goes, measured, and how to measure it again                                    |
| [testing.md](testing.md)           | How the suite runs and how to add to it                                                       |

## Before changing anything

The [main README](../README.md#how-it-works) states the two premises this design
rests on: a diff buffer is not valid source code, and its text is source and
nothing else. Both are load bearing.

The first is why highlights are collected from scratch buffers rather than from
the diff buffer, and why they can only be replayed as extmarks. The second is why
line numbers, markers, headers and separators are drawn rather than written, and
why putting non-source characters into the buffer is a regression rather than a
style choice.
