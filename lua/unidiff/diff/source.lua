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

--- @class unidiff.Skipped paths left out of a view, by why they were
--- @field binary string[]
--- @field conflicted string[]

--- Split a change list into the files that can be shown and those that cannot.
---
--- `conflicted` is only ever set on a `StatusEntry`; a plain change list has no
--- such field and leaves that group empty.
---
--- @generic T: {binary:boolean, path:string, conflicted?:boolean}
--- @param entries T[]
--- @return T[] wanted
--- @return unidiff.Skipped skipped
local function partition_showable(entries)
  local wanted, skipped = {}, { binary = {}, conflicted = {} }
  for _, e in ipairs(entries) do
    local group = e.conflicted and skipped.conflicted or e.binary and skipped.binary
    if group then
      group[#group + 1] = e.path
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
--- @return unidiff.Skipped skipped
--- @return unidiff.GitError? err
function M.for_rev(rev, root)
  local changes, err = git.changed(rev, root)
  if not changes then
    return nil, { binary = {}, conflicted = {} }, { what = 'git diff ' .. rev, stderr = err or '' }
  end
  local wanted, skipped = partition_showable(changes)

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
      label = status.change_label(c),
      ft = M.filetype_of(path),
      old_lines = old_lines or {},
      -- a deleted file has no working copy
      new_lines = c.status == 'D' and {} or M.working_lines(path),
    }
  end
  return sources, skipped
end

--- Read the two versions of every change a commit made: the file as its first
--- parent had it, and as the commit left it.
---
--- Unlike `for_rev` neither side comes from the working tree. The working tree
--- is not one of the versions being compared here, and it may no longer have
--- the file at all.
---
--- @param commit unidiff.Commit
--- @param changes unidiff.Change[] not binary; those have nothing to read
--- @param root string repository root
--- @return unidiff.Source[]
local function commit_sources(commit, changes, root)
  -- As in `for_rev`, a version the file does not have is left out of the
  -- request rather than asked for under a spec that would resolve to something
  -- else. The root commit adds every file it lists, so the parent it does not
  -- have is never named.
  local parent = commit.parents[1]
  local specs, old_spec, new_spec = {}, {}, {}
  for i, c in ipairs(changes) do
    if parent and c.status ~= 'A' then
      specs[#specs + 1] = ('%s:%s'):format(parent, c.old_path)
      old_spec[i] = #specs
    end
    if c.status ~= 'D' then
      specs[#specs + 1] = ('%s:%s'):format(commit.sha, c.path)
      new_spec[i] = #specs
    end
  end
  local blobs = git.batch_show(specs, root)

  local sources = {}
  for i, c in ipairs(changes) do
    local path = root .. '/' .. c.path
    sources[#sources + 1] = {
      path = path,
      label = status.change_label(c),
      ft = M.filetype_of(path),
      old_lines = old_spec[i] and blobs[old_spec[i]] or {},
      new_lines = new_spec[i] and blobs[new_spec[i]] or {},
    }
  end
  return sources
end

--- Every file a commit changed, in one view.
--- @param commit unidiff.Commit
--- @param root string repository root
--- @return unidiff.Source[]? sources
--- @return unidiff.Skipped skipped
--- @return unidiff.GitError? err
function M.for_commit(commit, root)
  local changes, err = git.changed_in(commit, root)
  if not changes then
    return nil,
      { binary = {}, conflicted = {} },
      { what = 'git diff ' .. commit.sha, stderr = err or '' }
  end
  local wanted, skipped = partition_showable(changes)
  return commit_sources(commit, wanted, root), skipped
end

--- One change of a commit, for a view showing a single file.
--- @param commit unidiff.Commit
--- @param change unidiff.Change
--- @param root string repository root
--- @return unidiff.Source? source nil when there is nothing to read
function M.for_commit_change(commit, change, root)
  if change.binary then
    return nil
  end
  return commit_sources(commit, { change }, root)[1]
end

--- Read the three versions of every entry: HEAD, the index and the working
--- tree. One diff over all three can show what is staged and what is not at the
--- same time, which is why this differs from `for_rev` and its two versions.
---
--- A version the file does not have is empty: an untracked file has neither of
--- the first two, a staged deletion has no index version, and a file deleted
--- from the working tree has no third.
---
--- @param entries unidiff.StatusEntry[] neither binary nor unmerged; those have
---        nothing to read
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
--- @return unidiff.Skipped skipped
--- @return unidiff.GitError? err
function M.for_uncommitted(root)
  local entries, err = status.list(root)
  if not entries then
    return nil, { binary = {}, conflicted = {} }, err
  end
  local wanted, skipped = partition_showable(entries)
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
