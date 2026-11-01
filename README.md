# gitview.nvim

A Git view for Neovim: uncommitted changes and recent commits in a sidebar, and
a GitHub-style unified diff beside it. Deleted and added lines share one column,
both syntax highlighted, and the buffer is still just text you can select, yank
and search.

- **Staged and unstaged changes in one diff**, with single lines stageable from it
- **Commits and ranges of commits**, read by moving the cursor through the list
- **Reviewing a range**, checking off each file once it has been read
- **Merge conflicts** shown with each side in its own color
- **Refreshed on its own** when the repository changes from anywhere else

## Requirements

Neovim 0.12+. Highlighting uses Tree-sitter where a parser exists and falls back
to legacy `:syntax` otherwise.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'ryym/gitview.nvim' }
```

With `vim.pack`:

```lua
vim.pack.add({ 'https://github.com/ryym/gitview.nvim' })
```

`setup()` is optional.

## Getting started

```vim
:Gitview
```

This opens a tab page with the sidebar and the diff. Moving the cursor in the
sidebar draws what it lands on, and `q` closes it.

## Limitations

- Discarding changes and committing are not implemented.
- A merge conflict can be read, but is resolved by editing the file.
- Highlighting is syntactic only, with no LSP semantic tokens.

## Documentation

- [Usage](docs/usage.md): every view and key, configuration, and limitations
- [Development](docs/README.md): how the code is organized, and how to work on it
