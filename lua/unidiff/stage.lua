--- Which git command moves a file into or out of the index.
---
--- The choice is made as plain data, apart from running it, so that the mapping
--- from a file's status to a command can be tested without a repository. It is
--- the same split the parsers in `git.lua` already follow: deciding what to ask
--- git is the part worth pinning down.
---
--- Only whole files are handled here. Staging part of a file means writing a new
--- index entry, which is a different mechanism entirely.
local git = require('unidiff.git')
local status = require('unidiff.status')

local M = {}

--- @class unidiff.StageAction
--- @field what string the command, as the user would recognise it in an error
--- @field args string[] argv after `git`

--- The command that stages everything uncommitted in one file.
---
--- `git add` has staged deletions as well as content since git 2.0, so a
--- change, an addition, a deletion and an untracked file all take the same
--- command and nothing here has to branch on which it is.
---
--- @param e unidiff.StatusEntry
--- @return unidiff.StageAction? action
--- @return string? why nothing to do, phrased for the user
function M.stage(e)
  if not status.has_unstaged(e) then
    return nil, ('nothing to stage in %s'):format(e.path)
  end
  return { what = 'git add', args = { 'add', '--', e.path } }
end

--- The command that takes one file's staged changes back out of the index.
---
--- Two things make this more than the inverse of `stage`:
---
--- - **A staged rename needs both of its names.** `git restore --staged` on the
---   new path alone restores that path and leaves the old one still deleted in
---   the index, which is a state the file never had. The entry carries both.
--- - **Without a HEAD there is nothing to restore from.** `git restore --staged`
---   fails outright, so the entry has to leave the index instead. `--cached`
---   never touches the working tree, and `-f` is needed because git otherwise
---   refuses to drop an index entry that matches neither the file nor HEAD —
---   which, before the first commit, is every staged file that was edited again.
---
--- @param e unidiff.StatusEntry
--- @param has_head boolean whether the repository has a commit; see `git.has_head`
--- @return unidiff.StageAction? action
--- @return string? why nothing to do, phrased for the user
function M.unstage(e, has_head)
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

--- @param action unidiff.StageAction
--- @param root string repository root
--- @return unidiff.GitError? err
function M.run(action, root)
  local res = git.run(vim.list_extend({ 'git' }, action.args), root)
  if res.ok then
    return nil
  end
  return { what = action.what, stderr = res.stderr }
end

return M
