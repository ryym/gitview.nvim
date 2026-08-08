local dlib = require('unidiff.diff')
local hl = require('unidiff.highlight')
local render = require('unidiff.render')

local M = {}

--- @class unidiff.Config
--- @field context integer
--- @field rev string
local config = {
  context = 3,
  rev = 'HEAD',
}

--- @param opts? unidiff.Config
function M.setup(opts)
  config = vim.tbl_extend('force', config, opts or {})
  render.setup_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', { callback = render.setup_highlights })
end

--- @param path string
--- @param rev string
--- @return string[]? lines nil when the blob does not exist (new file)
local function git_show(path, rev, cwd)
  local out = vim.system({ 'git', 'show', ('%s:./%s'):format(rev, path) }, {
    text = true,
    cwd = cwd,
  }):wait()
  if out.code ~= 0 then
    return nil
  end
  local text = out.stdout:gsub('\n$', '')
  return vim.split(text, '\n', { plain = true })
end

--- Open a unified diff of the current buffer against `rev`.
--- @param opts? {rev?:string, context?:integer}
function M.open(opts)
  opts = opts or {}
  local src = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(src)
  if file == '' then
    vim.notify('unidiff: buffer has no file', vim.log.levels.WARN)
    return
  end
  local dir = vim.fs.dirname(file)
  local rev = opts.rev or config.rev
  local context = opts.context or config.context

  local old_lines = git_show(vim.fs.basename(file), rev, dir)
  if not old_lines then
    vim.notify(('unidiff: %s not found in %s'):format(file, rev), vim.log.levels.WARN)
    return
  end
  local new_lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)

  local lang = vim.treesitter.language.get_lang(vim.bo[src].filetype) or vim.bo[src].filetype
  local ft = vim.bo[src].filetype

  local hunks = dlib.hunks(old_lines, new_lines)
  if #hunks == 0 then
    vim.notify('unidiff: no changes', vim.log.levels.INFO)
    return
  end
  local lines, hunk_rows, gaps = dlib.build(hunks, old_lines, new_lines, context)

  local old_buf = hl.ghost_buffer(old_lines, ft)
  local new_buf = hl.ghost_buffer(new_lines, ft)

  local view = {
    lines = lines,
    hunk_rows = hunk_rows,
    gaps = gaps,
    path = file,
    rev = rev,
  }
  local buf = render.render(view, old_buf, new_buf, lang)
  vim.api.nvim_buf_delete(old_buf, { force = true })
  vim.api.nvim_buf_delete(new_buf, { force = true })

  vim.api.nvim_buf_set_name(buf, ('unidiff://%s @ %s'):format(vim.fs.basename(file), rev))
  vim.cmd.tabnew()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  render.configure_window(win, buf)
  M.set_keymaps(buf)
  return buf
end

--- @param buf integer
function M.set_keymaps(buf)
  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, desc = desc })
  end
  map(']h', function()
    M.jump_hunk(1)
  end, 'unidiff: next hunk')
  map('[h', function()
    M.jump_hunk(-1)
  end, 'unidiff: previous hunk')
  map('q', '<Cmd>quit<CR>', 'unidiff: close')
  map('<CR>', M.goto_source, 'unidiff: jump to source line')
end

--- @param dir 1|-1
function M.jump_hunk(dir)
  local buf = vim.api.nvim_get_current_buf()
  local view = render.views[buf]
  if not view then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if dir > 0 then
    for _, r in ipairs(view.hunk_rows) do
      if r > cur then
        target = r
        break
      end
    end
  else
    for _, r in ipairs(view.hunk_rows) do
      if r < cur then
        target = r
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

function M.goto_source()
  local buf = vim.api.nvim_get_current_buf()
  local view = render.views[buf]
  if not view then
    return
  end
  local l = view.lines[vim.api.nvim_win_get_cursor(0)[1]]
  if not l then
    return
  end
  local lnum = l.new_lnum or l.old_lnum
  vim.cmd.tabclose()
  vim.cmd.edit(vim.fn.fnameescape(view.path))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
end

return M
