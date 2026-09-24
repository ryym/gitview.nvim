local config = require('unidiff.config')
local keymap = require('unidiff.diff.keymap')
local render = require('unidiff.diff.render')
local source = require('unidiff.diff.source')
local util = require('unidiff.util')
local vlib = require('unidiff.diff.view')

local M = {}

--- @param opts? unidiff.Config
function M.setup(opts)
  config.set(opts)
  -- Colors do not need this: they are defined on first render either way.
  render.setup_highlights()
end

--- Buffer names have to be unique, and closing a diff's tab leaves its buffer
--- behind, so opening the same command twice in one session would otherwise
--- fail outright. The earlier buffer is left alone: it may still be on screen
--- somewhere.
--- @param base string
--- @return string
local function unique_name(base)
  local taken = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    taken[vim.api.nvim_buf_get_name(buf)] = true
  end
  local name, n = base, 1
  while taken[name] do
    n = n + 1
    name = ('%s (%d)'):format(base, n)
  end
  return name
end

--- Show a view in a tab of its own.
---
--- Making the buffer and placing it are separate calls because a file list will
--- want to draw into a buffer it already has in a window of its own.
--- @param view unidiff.View
--- @param name string
--- @return integer bufnr
local function open_in_tab(view, name)
  local buf = render.create_buffer()
  render.draw(buf, view)
  vlib.dispose(view)

  vim.api.nvim_buf_set_name(buf, unique_name(name))
  vim.cmd.tabnew()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  render.configure_window(win, buf)
  keymap.set(buf)
  return buf
end

--- Open a unified diff of the current buffer against `rev`.
--- @param opts? {rev?:string, context?:integer, algorithm?:string, linematch?:integer}
--- @return integer? bufnr
function M.open(opts)
  opts = config.resolve(opts)
  local rev = opts.rev

  local src, err = source.for_buffer(vim.api.nvim_get_current_buf(), rev)
  if not src then
    util.warn(err)
    return
  end

  local view = vlib.build({ src }, rev, opts.context, config.diff_opts(opts))
  if not view then
    util.info('no changes')
    return
  end
  return open_in_tab(view, ('unidiff://%s @ %s'):format(src.label, rev))
end

--- Open one buffer holding the diff of every file that changed against `rev`.
--- @param opts? {rev?:string, context?:integer, algorithm?:string, linematch?:integer}
--- @return integer? bufnr
function M.open_all(opts)
  opts = config.resolve(opts)
  local rev = opts.rev
  local root = source.repo_root()
  if not root then
    return
  end

  local sources, skipped, err = source.for_rev(rev, root)
  if not sources then
    util.git_error(err)
    return
  end
  if #sources == 0 and #skipped == 0 then
    util.info(('no changes against %s'):format(rev))
    return
  end

  local view, unchanged = vlib.build(sources, rev, opts.context, config.diff_opts(opts))
  if not view then
    util.info('no textual changes')
    return
  end

  view.note = vlib.skipped_note(#skipped, #unchanged)
  return open_in_tab(view, ('unidiff://all @ %s'):format(rev))
end

--- Experimental: every uncommitted change in one buffer, as HEAD -> working
--- tree, with each changed line marked staged or unstaged.
--- @param opts? {context?:integer, algorithm?:string, linematch?:integer}
--- @return integer? bufnr
function M.open_mixed(opts)
  opts = config.resolve(opts)
  local root = source.repo_root()
  if not root then
    return
  end

  local sources, skipped, err = source.for_uncommitted(root)
  if not sources then
    util.git_error(err)
    return
  end

  local view, unchanged = vlib.build(sources, 'HEAD', opts.context, config.diff_opts(opts))
  if not view then
    util.info('no uncommitted textual changes')
    return
  end
  view.mixed = true
  view.rev = 'HEAD, staged + unstaged'
  view.note = vlib.skipped_note(#skipped, #unchanged)
  return open_in_tab(view, 'unidiff://mixed')
end

return M
