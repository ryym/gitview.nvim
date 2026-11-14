--- Folding `fixup!` and `amend!` commits into the commits they name, from a
--- commit of the list up to HEAD, as `git rebase -i --autosquash <commit>^`
--- typed by hand would.
---
--- Gitview checks only what git lets through and should not: git refuses a
--- dirty working tree, an untracked file about to be overwritten and the like on
--- its own, and says why.
local git = require('gitview.git')

local M = {}

--- @class gitview.Autosquashed what came of an autosquash
--- @field refused string? why the rebase was not run
--- @field failed string? what git said when the rebase failed or stopped, a
---        conflict included
--- @field was string? HEAD before the rebase, abbreviated; nil when the rebase was not run
--- @field moved boolean? whether HEAD moved
--- @field start gitview.Commit? the commit the rebase started from, as it is
---        now: rewritten, or the same one when nothing before it was

--- Whether `commit` is among those `base..head` names. The empty tree, which a
--- review from a root commit starts at, is not: no rebase rewrites it.
--- @param commit string
--- @param base string?
--- @param head string
--- @param cwd string
--- @return boolean
local function in_range(commit, base, head, cwd)
  return git.is_ancestor(commit, head, cwd) and not (base and git.is_ancestor(commit, base, cwd))
end

--- Why rewriting the commits `base..head` would do harm git does not check
--- for, if it would.
--- @param commits gitview.Commit[] `base..head`, newest first
--- @param base string?
--- @param head string
--- @param ends string[] the ends of a review, which are fixed by sha
--- @param cwd string
--- @return string?
local function harm_in(commits, base, head, ends, cwd)
  for _, c in ipairs(commits) do
    -- Refuse a merge, which git would flatten rather than refuse.
    if #c.parents > 1 then
      return ('%s is a merge'):format(c.sha)
    end
    -- Refuse a squash!: its message is there to be edited by hand, and with no
    -- editor the two messages would be committed joined as they are.
    if vim.startswith(c.subject, 'squash! ') then
      return ('%s is a squash!, whose message is edited by hand'):format(c.sha)
    end
  end
  for _, e in ipairs(ends) do
    if in_range(e, base, head, cwd) then
      return 'it would rewrite an end of the review'
    end
  end
  return nil
end

--- Autosquash from `sha` up to HEAD, unless that would do harm git does not
--- check for. Everything is checked against the repository as it is now, not
--- against a list on screen, which may be out of date. Run inside `git.async`,
--- so as not to block Neovim on the rebase.
--- @param sha string the commit to start from
--- @param ends string[] the ends of the review going on, which a rewrite would
---        leave pointing at commits no longer in the history
--- @param cwd string
--- @return gitview.Autosquashed
function M.run(sha, ends, cwd)
  local head = git.resolve_commit('HEAD', cwd)
  if not (head and git.is_ancestor(sha, head, cwd)) then
    return { refused = 'the commit is not in the history of HEAD' }
  end
  local base = git.resolve_commit(sha .. '^', cwd)
  local commits, err = git.log(nil, cwd, { from = base, to = head })
  if not commits or not commits[1] then
    return { failed = err or '' }
  end
  local harm = harm_in(commits, base, head, ends, cwd)
  if harm then
    return { refused = harm }
  end
  local res = git.autosquash(base, cwd)
  local now = git.resolve_commit('HEAD', cwd)
  -- Find `sha` as rewritten as the oldest commit after `base`, however the
  -- rebase ended. The range has no merge, so it is a line, and `sha` is its
  -- oldest: a fixup names an older commit than itself, so nothing folds `sha`
  -- into another. A rebase that stops has gone past `base` too, since
  -- `rebase -i` fast-forwards over the picks that change nothing.
  local after = git.log(nil, cwd, { from = base })
  -- Drop the progress git draws over itself with carriage returns, as a
  -- terminal would: it buries the message in the notification.
  local failed = not res.ok and (res.stderr:gsub('[^\n]*\r', '')) or nil
  return {
    failed = failed,
    was = commits[1].sha,
    moved = now ~= head,
    start = after and after[#after] or nil,
  }
end

return M
