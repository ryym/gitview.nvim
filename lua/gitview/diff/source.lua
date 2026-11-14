--- Everything a view is built from: which files differ, the contents of each
--- version, and the filetype to highlight them with.
---
--- This is the only part of the pipeline that reads git and the editor. What it
--- hands back is plain data, so `view.build` has nothing left to look up.
local config = require('gitview.config')
local git = require('gitview.git')
local status = require('gitview.status')
local util = require('gitview.util')

local M = {}

--- @class gitview.Source
--- @field path string absolute path
--- @field label string
--- @field name_end integer? see `status.label`
--- @field ft string filetype, resolved here so that building a view needs no
---       editor state. Empty for a file that is not to be highlighted.
--- @field old_lines string[]
--- @field new_lines string[]
--- @field index_lines string[]? given only for a mixed view; see gitview.diff.mixed
--- @field conflicted true? an unmerged file, shown as `new_lines` has it rather
---       than as a diff; see gitview.diff.conflict
--- @field old_rev string? the revision `old_lines` was read from, as git names
---       it: `HEAD` or a commit. nil when there is none to name: a root commit
---       has no old side, and a conflicted file only the working tree's.
--- @field new_rev string? the commit `new_lines` was read from; nil for the
---       working tree

--- The working tree's version of a file: the file on disk, never a buffer.
---
--- Which files changed is git's answer, and git reads the disk. A buffer can
--- disagree with it either way: it holds unsaved edits, or it predates a write
--- from outside that Neovim has not reloaded yet. Reading one would then show a
--- change git does not list, or hide one it does.
--- @param path string absolute path
--- @return string[]
function M.working_lines(path)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  return vim.fn.readfile(path)
end

--- The filetype to highlight `path` with, or `''` when it is not to be
--- highlighted.
---
--- A filetype listed in `no_highlight_filetypes` counts as none. Highlighting a language
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
  if vim.tbl_contains(config.values.no_highlight_filetypes, ft) then
    return ''
  end
  return ft
end

--- The repository Gitview acts on, as `git.current_root` finds it, saying so
--- when there is none.
--- @return string? root
function M.repo_root()
  local root = git.current_root()
  if not root then
    util.warn('not inside a git repository')
  end
  return root
end

--- @class gitview.Skipped paths left out of a view, by why they were
--- @field binary string[]
--- @field conflicts? {path:string, kind:string}[] paths of a merge that
---        conflicted and were left as git left them, so that they have no diff
---        to show; `kind` as `gitview.Remerge` names it

--- A `Skipped` with every group empty: what the error paths report, and what
--- `partition_showable` starts from.
--- @return gitview.Skipped
local function no_skipped()
  return { binary = {} }
end

--- Split a change list into the files that can be shown and those that cannot.
---
--- @generic T: {binary:boolean, path:string}
--- @param entries T[]
--- @return T[] wanted
--- @return gitview.Skipped skipped
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
--- @param range gitview.Range
--- @param changes gitview.Change[] not binary; those have nothing to read
--- @param root string repository root
--- @return gitview.Source[]
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
    local label, name_end = status.change_label(c)
    sources[#sources + 1] = {
      path = path,
      label = label,
      name_end = name_end,
      ft = M.filetype_of(path),
      old_lines = old_spec[i] and blobs[old_spec[i]] or {},
      new_lines = new_lines,
      old_rev = range.old,
      new_rev = range.new,
    }
  end
  return sources
end

--- Every file a range changed, in one view.
--- @param range gitview.Range
--- @param root string repository root
--- @param untracked string[]? passed on to `git.changed_between`
--- @return gitview.Source[]? sources
--- @return gitview.Skipped skipped
--- @return gitview.GitError? err
function M.for_range(range, root, untracked)
  local changes, err = git.changed_between(range, root, untracked)
  if not changes then
    return nil, no_skipped(), { what = 'git diff ' .. (range.new or range.old), stderr = err or '' }
  end
  local wanted, skipped = partition_showable(changes)
  return range_sources(range, wanted, root), skipped
end

--- One change of a range, for a view showing a single file.
--- @param range gitview.Range
--- @param change gitview.Change
--- @param root string repository root
--- @return gitview.Source? source nil when there is nothing to read
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
--- @param entries gitview.StatusEntry[] neither binary nor unmerged; the first
---        have nothing to read, and the second no index version at stage 0
--- @param root string repository root
--- @return gitview.Source[]
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
    local label, name_end = status.label(e)
    sources[#sources + 1] = {
      path = path,
      label = label,
      name_end = name_end,
      ft = M.filetype_of(path),
      old_lines = head_spec[i] and blobs[head_spec[i]] or {},
      index_lines = index_lines,
      new_lines = work_lines,
      old_rev = 'HEAD',
    }
  end
  return sources
end

--- An unmerged entry, read from the working tree alone.
---
--- Its index holds the merge stages and no stage 0, so there is no middle for a
--- mixed view, and HEAD has nothing to say about how the merge went. What the
--- working tree holds, conflict markers and all, is what is left to resolve. A
--- path deleted from it, as by a conflict that both sides deleted, is empty.
--- @param entry gitview.StatusEntry
--- @param root string repository root
--- @return gitview.Source
local function conflict_source(entry, root)
  local path = vim.fs.joinpath(root, entry.path)
  local label, name_end = status.label(entry)
  return {
    path = path,
    label = label,
    name_end = name_end,
    ft = M.filetype_of(path),
    old_lines = {},
    new_lines = M.working_lines(path),
    conflicted = true,
  }
end

--- Every entry's versions, for one view of everything uncommitted: three for
--- most, and the working tree's alone for an unmerged one. The sources are in
--- the order of `entries`.
--- @param entries gitview.StatusEntry[]
--- @param root string repository root
--- @return gitview.Source[] sources
--- @return gitview.Skipped skipped
function M.for_entries(entries, root)
  local showable, skipped = partition_showable(entries)
  -- The unmerged ones are read in place, and the slots of the rest filled in
  -- from the one batch they are read in.
  local sources, wanted, slots = {}, {}, {}
  for _, e in ipairs(showable) do
    if e.conflicted then
      sources[#sources + 1] = conflict_source(e, root)
    else
      wanted[#wanted + 1] = e
      sources[#sources + 1] = false
      slots[#wanted] = #sources
    end
  end
  for i, src in ipairs(sources_of(wanted, root)) do
    sources[slots[i]] = src
  end
  return sources, skipped
end

--- One entry's versions, for a view showing a single file. As in `for_entries`,
--- an unmerged entry has only the working tree's.
--- @param entry gitview.StatusEntry
--- @param root string repository root
--- @return gitview.Source? source nil for a binary file, which has nothing to read
function M.for_entry(entry, root)
  if entry.binary then
    return nil
  end
  if entry.conflicted then
    return conflict_source(entry, root)
  end
  return sources_of({ entry }, root)[1]
end

return M
