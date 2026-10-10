--- Which git command moves a file into or out of the index.
---
--- The choice is made as plain data, apart from running it, so that the mapping
--- from a file's status to a command can be tested without a repository. It is
--- the same split the parsers in `git.lua` already follow: deciding what to ask
--- git is the part worth pinning down.
---
--- Only whole files are handled here, one at a time or the files of a directory
--- together. Staging part of a file means writing a new index entry, which is a
--- different mechanism entirely.
local git = require('gitview.git')
local status = require('gitview.status')

local M = {}

--- @class gitview.StageAction
--- @field what string the command, as the user would recognise it in an error
--- @field args string[] argv after `git`
--- @field stdin string? fed to the command; the paths, when there may be more of
---        them than a command line takes

--- The command that stages everything uncommitted in one file.
---
--- `git add` has staged deletions as well as content since git 2.0, so a
--- change, an addition, a deletion and an untracked file all take the same
--- command and nothing here has to branch on which it is.
---
--- An unmerged path is allowed: `git add` on one marks the conflict resolved,
--- which is how git itself is told that the file in the working tree is the
--- answer. Unstaging has no such reading; see `unstage`.
---
--- @param e gitview.StatusEntry
--- @return gitview.StageAction? action
--- @return string? why nothing to do, phrased for the user
function M.stage(e)
  if not status.has_unstaged(e) then
    return nil, ('nothing to stage in %s'):format(e.path)
  end
  return { what = 'git add', args = { 'add', '--', e.path } }
end

--- The command that takes one file's staged changes back out of the index.
---
--- Three things make this more than the inverse of `stage`:
---
--- - **An unmerged path is refused.** `git restore --staged` on one succeeds and
---   leaves an ordinary modification: the three merge stages are gone and the
---   conflict is neither resolved nor still recorded. That is git's own
---   behaviour, but nobody presses `u` meaning to abandon a merge, so it is not
---   offered here.
--- - **A staged rename needs both of its names.** `git restore --staged` on the
---   new path alone restores that path and leaves the old one still deleted in
---   the index, which is a state the file never had. The entry carries both.
--- - **Without a HEAD there is nothing to restore from.** `git restore --staged`
---   fails outright, so the entry has to leave the index instead. `--cached`
---   never touches the working tree, and `-f` is needed because git otherwise
---   refuses to drop an index entry that matches neither the file nor HEAD —
---   which, before the first commit, is every staged file that was edited again.
---
--- @param e gitview.StatusEntry
--- @param has_head boolean whether the repository has a commit; see `git.has_head`
--- @return gitview.StageAction? action
--- @return string? why nothing to do, phrased for the user
function M.unstage(e, has_head)
  if e.conflicted then
    return nil, ('%s has an unresolved conflict; unstaging would discard it'):format(e.path)
  end
  if not status.has_staged(e) then
    return nil, ('nothing to unstage in %s'):format(e.path)
  end
  if not has_head then
    return { what = 'git rm --cached', args = { 'rm', '--cached', '-f', '-q', '--', e.path } }
  end
  local args = { 'restore', '--staged', '--', e.path }
  if e.head_path and e.head_path ~= e.path then
    args[#args + 1] = e.head_path
  end
  return { what = 'git restore --staged', args = args }
end

--- Arguments that read NUL-separated paths from stdin, for a directory's files.
local PATHS_FROM_STDIN = { '--pathspec-from-file=-', '--pathspec-file-nul' }

--- @param paths string[]
--- @return string
local function nul_joined(paths)
  return table.concat(paths, '\0')
end

--- Why a directory is refused when it holds an unmerged path, or nil.
---
--- Unstaging one is refused for the reason `unstage` gives. Staging one is
--- allowed file by file, where it is how a conflict is marked resolved, but
--- staging a whole directory would mark it resolved without that file ever
--- having been looked at.
--- @param entries gitview.StatusEntry[]
--- @param name string what to call the directory
--- @return string?
local function refused_for_conflict(entries, name)
  for _, e in ipairs(entries) do
    if e.conflicted then
      return ('%s has an unresolved conflict in %s; resolve it first'):format(name, e.path)
    end
  end
  return nil
end

--- The command that stages everything uncommitted in a directory.
---
--- The paths are the entries' own rather than the directory's, so that the
--- same rules as `stage` apply file by file.
---
--- @param entries gitview.StatusEntry[] the files in the directory
--- @param name string what to call the directory
--- @return gitview.StageAction? action
--- @return string? why nothing to do, phrased for the user
function M.stage_all(entries, name)
  local why = refused_for_conflict(entries, name)
  if why then
    return nil, why
  end
  local paths = {}
  for _, e in ipairs(entries) do
    if status.has_unstaged(e) then
      paths[#paths + 1] = e.path
    end
  end
  if #paths == 0 then
    return nil, ('nothing to stage in %s'):format(name)
  end
  return { what = 'git add', args = vim.list_extend({ 'add' }, PATHS_FROM_STDIN), stdin = nul_joined(paths) }
end

--- The command that takes a directory's staged changes back out of the index.
---
--- As with `unstage`, a rename takes both of its names. Naming the directory
--- instead would miss the old name of a file renamed into it from elsewhere,
--- leaving that path deleted in the index.
---
--- @param entries gitview.StatusEntry[] the files in the directory
--- @param has_head boolean whether the repository has a commit
--- @param name string what to call the directory
--- @return gitview.StageAction? action
--- @return string? why nothing to do, phrased for the user
function M.unstage_all(entries, has_head, name)
  local why = refused_for_conflict(entries, name)
  if why then
    return nil, why
  end
  local paths = {}
  for _, e in ipairs(entries) do
    if status.has_staged(e) then
      paths[#paths + 1] = e.path
      if has_head and e.head_path and e.head_path ~= e.path then
        paths[#paths + 1] = e.head_path
      end
    end
  end
  if #paths == 0 then
    return nil, ('nothing to unstage in %s'):format(name)
  end
  if not has_head then
    local args = vim.list_extend({ 'rm', '--cached', '-f', '-q' }, PATHS_FROM_STDIN)
    return { what = 'git rm --cached', args = args, stdin = nul_joined(paths) }
  end
  local args = vim.list_extend({ 'restore', '--staged' }, PATHS_FROM_STDIN)
  return { what = 'git restore --staged', args = args, stdin = nul_joined(paths) }
end

--- @param action gitview.StageAction
--- @param root string repository root
--- @return gitview.GitError? err
function M.run(action, root)
  local opts = action.stdin and { stdin = action.stdin } or nil
  local res = git.run(vim.list_extend({ 'git' }, action.args), root, opts)
  if res.ok then
    return nil
  end
  return { what = action.what, stderr = res.stderr }
end

return M
