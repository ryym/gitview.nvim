--- What is uncommitted, as one entry per file.
---
--- The file list shows a file once whatever it has changed, the way
--- `git status --short` does, rather than once under "staged" and again under
--- "unstaged". A file can differ from HEAD in the index, in the working tree,
--- or both, so each entry carries a status letter for each side; the diff for
--- an entry is always built from all three versions and needs no such split.
local git = require('unidiff.git')

local M = {}

--- The letter `git status --short` prints for a side that has not changed.
local UNCHANGED = ' '

--- Both letters of an untracked file. git prints `??`, and the file exists in
--- neither HEAD nor the index, so no other pair would describe it.
local UNTRACKED = '?'

--- @class unidiff.StatusEntry
--- @field path string repo-relative, as the index and the working tree name it
--- @field head_path string? repo-relative in HEAD; nil for a file HEAD lacks
--- @field index_status string one character, as `git status --short` prints X
--- @field worktree_status string one character, as it prints Y
--- @field in_index boolean whether the index holds a version of the file
--- @field binary boolean no diff can be shown

--- Build the entries from three listings.
---
--- Kept apart from reading git so that the joining rules can be tested against
--- listings that would be tedious to arrange in a real repository.
---
--- A file can appear in both change lists. `git diff` compares the index with
--- the working tree and names paths as the *index* has them, so a rename staged
--- but then edited again is `old -> new` in the first list and `new` in the
--- second: the index path is the only key both agree on.
---
--- @param staged unidiff.Change[] HEAD -> index
--- @param unstaged unidiff.Change[] index -> working tree
--- @param untracked string[] paths git is not tracking
--- @return unidiff.StatusEntry[] sorted by path
function M.entries(staged, unstaged, untracked)
  local entries, by_path = {}, {} --- @type unidiff.StatusEntry[], table<string, unidiff.StatusEntry>

  local function add(e)
    entries[#entries + 1], by_path[e.path] = e, e
    return e
  end

  for _, c in ipairs(staged) do
    add({
      path = c.path,
      head_path = c.status ~= 'A' and c.old_path or nil,
      index_status = c.status,
      worktree_status = UNCHANGED,
      -- a staged deletion leaves the index with no version of the file
      in_index = c.status ~= 'D',
      binary = c.binary,
    })
  end

  for _, c in ipairs(unstaged) do
    local e = by_path[c.old_path]
    if not e then
      -- nothing staged, so HEAD and the index agree on this path
      e = add({
        path = c.old_path,
        head_path = c.old_path,
        index_status = UNCHANGED,
        worktree_status = UNCHANGED,
        in_index = true,
        binary = false,
      })
    end
    e.worktree_status = c.status
    e.binary = e.binary or c.binary
  end

  for _, path in ipairs(untracked) do
    add({
      path = path,
      head_path = nil,
      index_status = UNTRACKED,
      worktree_status = UNTRACKED,
      in_index = false,
      binary = false,
    })
  end

  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  return entries
end

--- Whether the index differs from HEAD for this entry.
---
--- An untracked file is in neither, so it counts as unstaged only. Both letters
--- are `?` for it, which is why the test is not simply "not unchanged".
---
--- @param e unidiff.StatusEntry
--- @return boolean
function M.has_staged(e)
  return e.index_status ~= UNCHANGED and e.index_status ~= UNTRACKED
end

--- Whether the working tree differs from the index for this entry.
--- @param e unidiff.StatusEntry
--- @return boolean
function M.has_unstaged(e)
  return e.worktree_status ~= UNCHANGED
end

--- How much of a file to look at before calling it text. This is git's own
--- rule, and using a different one would disagree with the `binary` flag that
--- `git diff --numstat` gives every tracked file.
local SNIFF_BYTES = 8000

--- Whether a file looks binary, by the presence of a NUL byte near its start.
---
--- Tracked files are classified by git itself, but an untracked file is never
--- named by `git diff`, so there is nothing to read the answer from.
---
--- @param path string absolute path
--- @return boolean
function M.looks_binary(path)
  local f = io.open(path, 'rb')
  if not f then
    return false
  end
  local head = f:read(SNIFF_BYTES) or ''
  f:close()
  return head:find('\0', 1, true) ~= nil
end

--- Every uncommitted change in the repository.
--- @param root string repository root
--- @return unidiff.StatusEntry[]? entries
--- @return unidiff.GitError? err
function M.list(root)
  local staged, staged_err = git.changed_staged(root)
  if not staged then
    return nil, { what = 'git diff --cached', stderr = staged_err or '' }
  end
  local unstaged, unstaged_err = git.changed_unstaged(root)
  if not unstaged then
    return nil, { what = 'git diff', stderr = unstaged_err or '' }
  end
  local untracked, untracked_err = git.untracked(root)
  if not untracked then
    return nil, { what = 'git ls-files --others', stderr = untracked_err or '' }
  end

  local entries = M.entries(staged, unstaged, untracked)
  for _, e in ipairs(entries) do
    if e.index_status == UNTRACKED then
      e.binary = M.looks_binary(root .. '/' .. e.path)
    end
  end
  return entries
end

--- The name to show for an entry. A rename is the one case where the file has
--- two names worth printing.
--- @param e unidiff.StatusEntry
--- @return string
function M.label(e)
  if e.head_path and e.head_path ~= e.path then
    return ('%s -> %s'):format(e.head_path, e.path)
  end
  return e.path
end

return M
