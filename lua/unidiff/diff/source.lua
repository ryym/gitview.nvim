--- Everything a view is built from: which files differ, the contents of each
--- version, and the filetype to highlight them with.
---
--- This is the only part of the pipeline that reads git and the editor. What it
--- hands back is plain data, so `view.build` has nothing left to look up.
local git = require('unidiff.git')
local status = require('unidiff.status')
local util = require('unidiff.util')

local M = {}

--- @class unidiff.Source
--- @field path string absolute path
--- @field label string
--- @field ft string filetype, resolved here so that building a view needs no
---       editor state
--- @field old_lines string[]
--- @field new_lines string[]
--- @field index_lines string[]? given only for a mixed view; see unidiff.diff.mixed

--- The new side of the diff is whatever the user is looking at: a loaded buffer
--- with unsaved changes, otherwise the file on disk.
--- @param path string absolute path
--- @return string[]
function M.working_lines(path)
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
function M.filetype_of(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.bo[buf].filetype ~= '' then
    return vim.bo[buf].filetype
  end
  return vim.filetype.match({ filename = path }) or ''
end

--- The repository of the current buffer, falling back to that of the cwd.
--- @return string? root
function M.repo_root()
  local cwd = vim.fn.getcwd()
  local buf_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(0))
  local root = git.root(buf_dir ~= '' and buf_dir or cwd) or git.root(cwd)
  if not root then
    util.warn('not inside a git repository')
  end
  return root
end

--- @param c unidiff.Change
--- @return string
local function label_of(c)
  return c.status == 'R' and ('%s -> %s'):format(c.old_path, c.path) or c.path
end

--- Split a change list into the files that can be shown and the binary ones.
--- @generic T: {binary:boolean, path:string}
--- @param entries T[]
--- @return T[] wanted
--- @return string[] skipped
local function partition_binary(entries)
  local wanted, skipped = {}, {}
  for _, e in ipairs(entries) do
    if e.binary then
      skipped[#skipped + 1] = e.path
    else
      wanted[#wanted + 1] = e
    end
  end
  return wanted, skipped
end

--- The current buffer against `rev`.
--- @param buf integer
--- @param rev string
--- @return unidiff.Source? source
--- @return string? err why there is none
function M.for_buffer(buf, rev)
  local file = vim.api.nvim_buf_get_name(buf)
  if file == '' then
    return nil, 'buffer has no file'
  end
  local old_lines = git.show('./' .. vim.fs.basename(file), rev, vim.fs.dirname(file))
  if not old_lines then
    return nil, ('%s not found in %s'):format(file, rev)
  end
  return {
    path = file,
    label = vim.fs.basename(file),
    ft = M.filetype_of(file),
    old_lines = old_lines,
    new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
  }
end

--- Every file that differs between `rev` and the working tree.
--- @param rev string
--- @param root string repository root
--- @return unidiff.Source[]? sources
--- @return string[] skipped binary paths
--- @return unidiff.GitError? err
function M.for_rev(rev, root)
  local changes, err = git.changed(rev, root)
  if not changes then
    return nil, {}, { what = 'git diff ' .. rev, stderr = err or '' }
  end
  local wanted, skipped = partition_binary(changes)

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
      label = label_of(c),
      ft = M.filetype_of(path),
      old_lines = old_lines or {},
      -- a deleted file has no working copy
      new_lines = c.status == 'D' and {} or M.working_lines(path),
    }
  end
  return sources, skipped
end

--- Read the three versions of every entry: HEAD, the index and the working
--- tree. One diff over all three can show what is staged and what is not at the
--- same time, which is why this differs from `for_rev` and its two versions.
---
--- A version the file does not have is empty: an untracked file has neither of
--- the first two, a staged deletion has no index version, and a file deleted
--- from the working tree has no third.
---
--- @param entries unidiff.StatusEntry[] not binary; those have nothing to read
--- @param root string repository root
--- @return unidiff.Source[]
local function sources_of(entries, root)
  -- `:path` is the index's copy of a path. As in for_rev, a version that does
  -- not exist is left out of the request.
  local specs, head_spec, index_spec = {}, {}, {}
  for i, e in ipairs(entries) do
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
  for i, e in ipairs(entries) do
    local path = root .. '/' .. e.path
    local index_lines = index_spec[i] and blobs[index_spec[i]] or {}
    -- an unchanged working tree is the index, which spares a read
    local work_lines = index_lines
    if e.worktree_status ~= ' ' then
      work_lines = e.worktree_status == 'D' and {} or M.working_lines(path)
    end
    sources[#sources + 1] = {
      path = path,
      label = status.label(e),
      ft = M.filetype_of(path),
      old_lines = head_spec[i] and blobs[head_spec[i]] or {},
      index_lines = index_lines,
      new_lines = work_lines,
    }
  end
  return sources
end

--- Every uncommitted change, as three versions per file.
--- @param root string repository root
--- @return unidiff.Source[]? sources
--- @return string[] skipped binary paths
--- @return unidiff.GitError? err
function M.for_uncommitted(root)
  local entries, err = status.list(root)
  if not entries then
    return nil, {}, err
  end
  local wanted, skipped = partition_binary(entries)
  return sources_of(wanted, root), skipped
end

--- One entry's three versions, for a view showing a single file.
--- @param entry unidiff.StatusEntry
--- @param root string repository root
--- @return unidiff.Source? source nil when there is nothing to read: a binary
---         file, or an unmerged one, whose index version is not at stage 0
function M.for_entry(entry, root)
  if entry.binary or entry.conflicted then
    return nil
  end
  return sources_of({ entry }, root)[1]
end

return M
