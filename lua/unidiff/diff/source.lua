--- Everything a view is built from: which files differ, the contents of each
--- version, and the filetype to highlight them with.
---
--- This is the only part of the pipeline that reads git and the editor. What it
--- hands back is plain data, so `view.build` has nothing left to look up.
local config = require('unidiff.config')
local git = require('unidiff.git')
local status = require('unidiff.status')
local util = require('unidiff.util')

local M = {}

--- @class unidiff.Source
--- @field path string absolute path
--- @field label string
--- @field ft string filetype, resolved here so that building a view needs no
---       editor state. Empty for a file that is not to be highlighted.
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

--- The filetype to highlight `path` with, or `''` when it is not to be
--- highlighted.
---
--- A filetype listed in `no_highlight` counts as none. Highlighting a language
--- without a Tree-sitter parser means loading its syntax file into every ghost
--- buffer, and some are costly enough that a view of many such files is slow to
--- open; dropping the filetype here is what leaves the ghost buffers bare.
--- @param path string
--- @return string filetype
function M.filetype_of(path)
  local buf = vim.fn.bufnr(path)
  local ft
  if buf ~= -1 and vim.bo[buf].filetype ~= '' then
    ft = vim.bo[buf].filetype
  else
    ft = vim.filetype.match({ filename = path }) or ''
  end
  if vim.tbl_contains(config.values.no_highlight, ft) then
    return ''
  end
  return ft
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

--- A `Skipped` with every group empty: what the error paths report, and what
--- `partition_showable` starts from.
--- @return unidiff.Skipped
local function no_skipped()
  return { binary = {} }
end

--- Split a change list into the files that can be shown and those that cannot.
---
--- @generic T: {binary:boolean, path:string}
--- @param entries T[]
--- @return T[] wanted
--- @return unidiff.Skipped skipped
local function partition_showable(entries)
  local wanted, skipped = {}, no_skipped()
  for _, e in ipairs(entries) do
    if e.binary then
      skipped.binary[#skipped.binary + 1] = e.path
    else
      wanted[#wanted + 1] = e
    end
  end
  return wanted, skipped
end

--- Read the two versions of every change in a range: the file as the old side
--- had it, and as the new side left it.
---
--- A committed side is read from the object database, never from the working
--- tree, which may no longer have the file at all. Only a range ending at the
--- working tree reads it, and then for the new side alone.
---
--- @param range unidiff.Range
--- @param changes unidiff.Change[] not binary; those have nothing to read
--- @param root string repository root
--- @return unidiff.Source[]
local function range_sources(range, changes, root)
  -- One `git cat-file` for every version: a process per file is what makes a
  -- large diff slow, not the diffing itself. A version the file does not have is
  -- left out of the request rather than asked for under a spec that would
  -- resolve to something else. A root commit adds every file it lists, so the
  -- old side it does not have is never named.
  local specs, old_spec, new_spec = {}, {}, {}
  for i, c in ipairs(changes) do
    if range.old and c.status ~= 'A' then
      specs[#specs + 1] = ('%s:%s'):format(range.old, c.old_path)
      old_spec[i] = #specs
    end
    if range.new and c.status ~= 'D' then
      specs[#specs + 1] = ('%s:%s'):format(range.new, c.path)
      new_spec[i] = #specs
    end
  end
  local blobs = git.batch_show(specs, root)

  local sources = {}
  for i, c in ipairs(changes) do
    local path = vim.fs.joinpath(root, c.path)
    local new_lines
    if range.new then
      new_lines = new_spec[i] and blobs[new_spec[i]] or {}
    else
      new_lines = c.status == 'D' and {} or M.working_lines(path)
    end
    sources[#sources + 1] = {
      path = path,
      label = status.change_label(c),
      ft = M.filetype_of(path),
      old_lines = old_spec[i] and blobs[old_spec[i]] or {},
      new_lines = new_lines,
    }
  end
  return sources
end

--- Every file a range changed, in one view.
--- @param range unidiff.Range
--- @param root string repository root
--- @return unidiff.Source[]? sources
--- @return unidiff.Skipped skipped
--- @return unidiff.GitError? err
function M.for_range(range, root)
  local changes, err = git.changed_between(range, root)
  if not changes then
    return nil, no_skipped(), { what = 'git diff ' .. (range.new or range.old), stderr = err or '' }
  end
  local wanted, skipped = partition_showable(changes)
  return range_sources(range, wanted, root), skipped
end

--- One change of a range, for a view showing a single file.
--- @param range unidiff.Range
--- @param change unidiff.Change
--- @param root string repository root
--- @return unidiff.Source? source nil when there is nothing to read
function M.for_range_change(range, change, root)
  if change.binary then
    return nil
  end
  return range_sources(range, { change }, root)[1]
end

--- Read the three versions of every entry: HEAD, the index and the working
--- tree. One diff over all three can show what is staged and what is not at the
--- same time, which is why this differs from the two versions a range has.
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
  -- `:path` is the index's copy of a path. As in `range_sources`, a version that
  -- does not exist is left out of the request.
  local specs, head_spec, index_spec = {}, {}, {}
  for i, e in ipairs(entries) do
    if e.head_path then
      specs[#specs + 1] = 'HEAD:' .. e.head_path
      head_spec[i] = #specs
    end
    if status.in_index(e) then
      specs[#specs + 1] = ':' .. e.path
      index_spec[i] = #specs
    end
  end
  local blobs = git.batch_show(specs, root)

  local sources = {}
  for i, e in ipairs(entries) do
    local path = vim.fs.joinpath(root, e.path)
    local index_lines = index_spec[i] and blobs[index_spec[i]] or {}
    -- an unchanged working tree is the index, which spares a read
    local work_lines = index_lines
    if status.has_unstaged(e) then
      work_lines = status.is_deleted(e) and {} or M.working_lines(path)
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
