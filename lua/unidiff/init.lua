local dlib = require('unidiff.diff')
local git = require('unidiff.git')
local hl = require('unidiff.highlight')
local render = require('unidiff.render')

local M = {}

--- @class unidiff.Config
--- @field context integer
--- @field rev string
--- @field algorithm string
--- @field linematch integer 0 keeps hunks identical to `git diff`; see diff.hunks
local config = {
  context = 3,
  rev = 'HEAD',
  algorithm = 'histogram',
  linematch = 0,
}

--- @param opts? unidiff.Config
function M.setup(opts)
  config = vim.tbl_extend('force', config, opts or {})
  -- Colors do not need this: they are defined on first render either way.
  render.setup_highlights()
end

--- The new side of the diff is whatever the user is looking at: a loaded buffer
--- with unsaved changes, otherwise the file on disk.
--- @param path string absolute path
--- @return string[]
local function working_lines(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  return vim.fn.readfile(path)
end

--- @param path string
--- @return string filetype
local function filetype_of(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.bo[buf].filetype ~= '' then
    return vim.bo[buf].filetype
  end
  return vim.filetype.match({ filename = path }) or ''
end

--- @class unidiff.Source
--- @field path string absolute path
--- @field label string
--- @field old_lines string[]
--- @field new_lines string[]

--- Turn sources into a renderable view, concatenating their diffs.
--- @param sources unidiff.Source[]
--- @param rev string
--- @param context integer
--- @param diff_opts table
--- @return unidiff.View? view nil when nothing differs
--- @return string[] unchanged labels of sources with no textual difference,
---         such as a pure rename or a mode change
local function build_view(sources, rev, context, diff_opts)
  local lines, files, hunk_rows = {}, {}, {}
  local unchanged = {}

  for _, src in ipairs(sources) do
    local hunks = dlib.hunks(src.old_lines, src.new_lines, diff_opts)
    if #hunks == 0 then
      unchanged[#unchanged + 1] = src.label
    else
      local flines, fhunks = dlib.build(hunks, src.old_lines, src.new_lines, context)
      local ft = filetype_of(src.path)
      local lang = vim.treesitter.language.get_lang(ft) or ft

      -- A blank line keeps the header off the previous file's last diff line.
      if #lines > 0 then
        lines[#lines + 1] = { text = '', kind = 'blank' }
      end
      lines[#lines + 1] = { text = src.label, kind = 'file' }
      local offset = #lines

      files[#files + 1] = {
        path = src.path,
        label = src.label,
        old_buf = hl.ghost_buffer(src.old_lines, ft, lang),
        new_buf = hl.ghost_buffer(src.new_lines, ft, lang),
        lang = lang,
        row = offset,
      }
      local index = #files

      for _, l in ipairs(flines) do
        l.file = index
        lines[#lines + 1] = l
      end
      for _, r in ipairs(fhunks) do
        hunk_rows[#hunk_rows + 1] = r + offset
      end
    end
  end

  if #files == 0 then
    return nil, unchanged
  end
  return {
    lines = lines,
    files = files,
    hunk_rows = hunk_rows,
    rev = rev,
  }, unchanged
end

--- @param view unidiff.View
--- @param name string
--- @return integer bufnr
local function open_view(view, name)
  local buf = render.render(view)
  for _, f in ipairs(view.files) do
    vim.api.nvim_buf_delete(f.old_buf, { force = true })
    vim.api.nvim_buf_delete(f.new_buf, { force = true })
  end

  vim.api.nvim_buf_set_name(buf, name)
  vim.cmd.tabnew()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  render.configure_window(win, buf)
  M.set_keymaps(buf)
  return buf
end

--- Open a unified diff of the current buffer against `rev`.
--- @param opts? {rev?:string, context?:integer, algorithm?:string, linematch?:integer}
--- @return integer? bufnr
function M.open(opts)
  opts = opts or {}
  local src = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(src)
  if file == '' then
    vim.notify('unidiff: buffer has no file', vim.log.levels.WARN)
    return
  end
  local rev = opts.rev or config.rev

  local old_lines = git.show('./' .. vim.fs.basename(file), rev, vim.fs.dirname(file))
  if not old_lines then
    vim.notify(('unidiff: %s not found in %s'):format(file, rev), vim.log.levels.WARN)
    return
  end

  local view = build_view({
    {
      path = file,
      label = vim.fs.basename(file),
      old_lines = old_lines,
      new_lines = vim.api.nvim_buf_get_lines(src, 0, -1, false),
    },
  }, rev, opts.context or config.context, {
    algorithm = opts.algorithm or config.algorithm,
    linematch = opts.linematch or config.linematch,
  })
  if not view then
    vim.notify('unidiff: no changes', vim.log.levels.INFO)
    return
  end

  return open_view(view, ('unidiff://%s @ %s'):format(vim.fs.basename(file), rev))
end

--- Open one buffer holding the diff of every file that changed against `rev`.
--- @param opts? {rev?:string, context?:integer, algorithm?:string, linematch?:integer}
--- @return integer? bufnr
function M.open_all(opts)
  opts = opts or {}
  local rev = opts.rev or config.rev
  local cwd = vim.fn.getcwd()
  local buf_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(0))
  local root = git.root(buf_dir ~= '' and buf_dir or cwd) or git.root(cwd)
  if not root then
    vim.notify('unidiff: not inside a git repository', vim.log.levels.WARN)
    return
  end

  local changes = git.changed(rev, root)
  if not changes or #changes == 0 then
    vim.notify(('unidiff: no changes against %s'):format(rev), vim.log.levels.INFO)
    return
  end

  local wanted, skipped = {}, {}
  for _, c in ipairs(changes) do
    if c.binary then
      skipped[#skipped + 1] = c.path
    else
      wanted[#wanted + 1] = c
    end
  end

  -- One `git cat-file` for every old version: a process per file is what makes
  -- a large diff slow, not the diffing itself. Added files have no blob in
  -- `rev`, so they are left out of the request rather than asked for under a
  -- spec that would resolve to the root tree.
  local specs, spec_of = {}, {}
  for i, c in ipairs(wanted) do
    if c.status ~= 'A' then
      specs[#specs + 1] = ('%s:%s'):format(rev, c.old_path)
      spec_of[i] = #specs
    end
  end
  local blobs = git.batch_show(specs, root)

  local sources = {}
  for i, c in ipairs(wanted) do
    local path = root .. '/' .. c.path
    local old_lines = spec_of[i] and blobs[spec_of[i]]
    sources[#sources + 1] = {
      path = path,
      label = c.status == 'R' and ('%s -> %s'):format(c.old_path, c.path) or c.path,
      old_lines = old_lines or {},
      -- a deleted file has no working copy
      new_lines = c.status == 'D' and {} or working_lines(path),
    }
  end

  local view, unchanged = build_view(sources, rev, opts.context or config.context, {
    algorithm = opts.algorithm or config.algorithm,
    linematch = opts.linematch or config.linematch,
  })
  if not view then
    vim.notify('unidiff: no textual changes', vim.log.levels.INFO)
    return
  end

  -- A pure rename or a mode change produces no hunks and so has no rows to show,
  -- but dropping it silently would hide a real change.
  local notes = {}
  if #skipped > 0 then
    notes[#notes + 1] = ('%d binary'):format(#skipped)
  end
  if #unchanged > 0 then
    notes[#notes + 1] = ('%d without textual change'):format(#unchanged)
  end
  if #notes > 0 then
    view.note = '(' .. table.concat(notes, ', ') .. ' not shown)'
  end

  return open_view(view, ('unidiff://all @ %s'):format(rev))
end

--- @param buf integer
function M.set_keymaps(buf)
  local map = function(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, desc = desc })
  end
  map(']h', function()
    M.jump(1, 'hunk_rows')
  end, 'unidiff: next hunk')
  map('[h', function()
    M.jump(-1, 'hunk_rows')
  end, 'unidiff: previous hunk')
  map(']f', function()
    M.jump(1, 'files')
  end, 'unidiff: next file')
  map('[f', function()
    M.jump(-1, 'files')
  end, 'unidiff: previous file')
  map('q', '<Cmd>quit<CR>', 'unidiff: close')
  map('<CR>', M.goto_source, 'unidiff: jump to source line')
end

--- @param dir 1|-1
--- @param field 'hunk_rows'|'files'
function M.jump(dir, field)
  local view = render.views[vim.api.nvim_get_current_buf()]
  if not view then
    return
  end
  local rows = {}
  for _, entry in ipairs(view[field]) do
    rows[#rows + 1] = type(entry) == 'table' and entry.row or entry
  end

  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  for _, r in ipairs(rows) do
    if dir > 0 and r > cur then
      target = r
      break
    elseif dir < 0 and r < cur then
      target = r
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
  -- separators and file headers point at no single source line
  if not l or not dlib.source_kinds[l.kind] then
    return
  end
  local path = view.files[l.file].path
  local lnum = l.new_lnum or l.old_lnum
  vim.cmd.tabclose()
  vim.cmd.edit(vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
end

return M
