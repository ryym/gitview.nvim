local config = require('unidiff.config')
local dlib = require('unidiff.diff')
local git = require('unidiff.git')
local hl = require('unidiff.highlight')
local mixed = require('unidiff.mixed')
local render = require('unidiff.render')
local util = require('unidiff.util')

local M = {}

--- @param opts? unidiff.Config
function M.setup(opts)
  config.set(opts)
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
--- @field index_lines string[]? given only for a mixed view; see unidiff.mixed

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
    local flines, fhunks
    if src.index_lines then
      flines, fhunks =
        mixed.build(src.old_lines, src.index_lines, src.new_lines, context, diff_opts)
    else
      local hunks = dlib.hunks(src.old_lines, src.new_lines, diff_opts)
      if #hunks > 0 then
        flines, fhunks = dlib.build(hunks, src.old_lines, src.new_lines, context)
      end
    end
    if not flines then
      unchanged[#unchanged + 1] = src.label
    else
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
        index_buf = src.index_lines and hl.ghost_buffer(src.index_lines, ft, lang),
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
    if f.index_buf then
      vim.api.nvim_buf_delete(f.index_buf, { force = true })
    end
  end

  vim.api.nvim_buf_set_name(buf, name)
  vim.cmd.tabnew()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  render.configure_window(win, buf)
  M.set_keymaps(buf)
  return buf
end

--- A pure rename or a mode change produces no hunks and so has no rows to show,
--- but dropping it silently would hide a real change.
--- @param binary integer
--- @param unchanged integer
--- @return string?
local function skipped_note(binary, unchanged)
  local notes = {}
  if binary > 0 then
    notes[#notes + 1] = ('%d binary'):format(binary)
  end
  if unchanged > 0 then
    notes[#notes + 1] = ('%d without textual change'):format(unchanged)
  end
  if #notes > 0 then
    return '(' .. table.concat(notes, ', ') .. ' not shown)'
  end
end

--- Open a unified diff of the current buffer against `rev`.
--- @param opts? {rev?:string, context?:integer, algorithm?:string, linematch?:integer}
--- @return integer? bufnr
function M.open(opts)
  opts = config.resolve(opts)
  local src = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(src)
  if file == '' then
    util.warn('buffer has no file')
    return
  end
  local rev = opts.rev

  local old_lines = git.show('./' .. vim.fs.basename(file), rev, vim.fs.dirname(file))
  if not old_lines then
    util.warn(('%s not found in %s'):format(file, rev))
    return
  end

  local view = build_view({
    {
      path = file,
      label = vim.fs.basename(file),
      old_lines = old_lines,
      new_lines = vim.api.nvim_buf_get_lines(src, 0, -1, false),
    },
  }, rev, opts.context, config.diff_opts(opts))
  if not view then
    util.info('no changes')
    return
  end

  return open_view(view, ('unidiff://%s @ %s'):format(vim.fs.basename(file), rev))
end

--- The repository of the current buffer, falling back to that of the cwd.
--- @return string? root
local function repo_root()
  local cwd = vim.fn.getcwd()
  local buf_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(0))
  local root = git.root(buf_dir ~= '' and buf_dir or cwd) or git.root(cwd)
  if not root then
    util.warn('not inside a git repository')
  end
  return root
end

--- Open one buffer holding the diff of every file that changed against `rev`.
--- @param opts? {rev?:string, context?:integer, algorithm?:string, linematch?:integer}
--- @return integer? bufnr
function M.open_all(opts)
  opts = config.resolve(opts)
  local rev = opts.rev
  local root = repo_root()
  if not root then
    return
  end

  local changes, err = git.changed(rev, root)
  if not changes then
    util.git_error('git diff ' .. rev, err)
    return
  end
  if #changes == 0 then
    util.info(('no changes against %s'):format(rev))
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

  local view, unchanged = build_view(sources, rev, opts.context, config.diff_opts(opts))
  if not view then
    util.info('no textual changes')
    return
  end

  view.note = skipped_note(#skipped, #unchanged)
  return open_view(view, ('unidiff://all @ %s'):format(rev))
end

--- Experimental: every uncommitted change in one buffer, as HEAD -> working
--- tree, with each changed line marked staged or unstaged.
--- @param opts? {context?:integer, algorithm?:string, linematch?:integer}
--- @return integer? bufnr
function M.open_mixed(opts)
  opts = config.resolve(opts)
  local root = repo_root()
  if not root then
    return
  end
  local staged, staged_err = git.changed_staged(root)
  if not staged then
    util.git_error('git diff --cached', staged_err)
    return
  end
  local unstaged, unstaged_err = git.changed_unstaged(root)
  if not unstaged then
    util.git_error('git diff', unstaged_err)
    return
  end

  --- @class unidiff.MixedEntry
  --- @field path string repo-relative, in the index and the working tree
  --- @field head_path string? repo-relative in HEAD; nil when added
  --- @field label string
  --- @field in_index boolean
  --- @field unstaged unidiff.Change? set when the working tree differs
  --- @field binary boolean

  -- A file can have staged changes, unstaged ones, or both. Index -> working
  -- tree compares paths as the index has them, so that is the key to join on.
  local entries, by_path = {}, {} --- @type unidiff.MixedEntry[], table<string, unidiff.MixedEntry>
  for _, c in ipairs(staged) do
    local e = {
      path = c.path,
      head_path = c.status ~= 'A' and c.old_path or nil,
      label = c.status == 'R' and ('%s -> %s'):format(c.old_path, c.path) or c.path,
      in_index = c.status ~= 'D',
      binary = c.binary,
    }
    entries[#entries + 1], by_path[c.path] = e, e
  end
  for _, c in ipairs(unstaged) do
    local e = by_path[c.old_path]
    if not e then
      -- no staged change: HEAD and the index agree on this path
      e = {
        path = c.old_path,
        head_path = c.old_path,
        label = c.old_path,
        in_index = true,
        binary = false,
      }
      entries[#entries + 1], by_path[c.old_path] = e, e
    end
    e.unstaged = c
    e.binary = e.binary or c.binary
  end
  -- files with only unstaged changes were appended after the staged ones
  table.sort(entries, function(a, b)
    return a.path < b.path
  end)

  local wanted, skipped = {}, {}
  for _, e in ipairs(entries) do
    if e.binary then
      skipped[#skipped + 1] = e.path
    else
      wanted[#wanted + 1] = e
    end
  end

  -- `:path` is the index's copy of a path. As in open_all, a version that does
  -- not exist is left out of the request.
  local specs, head_spec, index_spec = {}, {}, {}
  for i, e in ipairs(wanted) do
    if e.head_path then
      specs[#specs + 1] = 'HEAD:' .. e.head_path
      head_spec[i] = #specs
    end
    if e.in_index then
      specs[#specs + 1] = ':' .. e.path
      index_spec[i] = #specs
    end
  end
  local blobs = git.batch_show(specs, root)

  local sources = {}
  for i, e in ipairs(wanted) do
    local path = root .. '/' .. e.path
    local index_lines = index_spec[i] and blobs[index_spec[i]] or {}
    local work_lines = index_lines
    if e.unstaged then
      work_lines = e.unstaged.status == 'D' and {} or working_lines(path)
    end
    sources[#sources + 1] = {
      path = path,
      label = e.label,
      old_lines = head_spec[i] and blobs[head_spec[i]] or {},
      index_lines = index_lines,
      new_lines = work_lines,
    }
  end

  local view, unchanged = build_view(sources, 'HEAD', opts.context, config.diff_opts(opts))
  if not view then
    util.info('no uncommitted textual changes')
    return
  end
  view.mixed = true
  view.rev = 'HEAD, staged + unstaged'
  view.note = skipped_note(#skipped, #unchanged)
  return open_view(view, 'unidiff://mixed')
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
