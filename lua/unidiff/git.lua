local M = {}

--- @class unidiff.Change
--- @field status 'A'|'M'|'D'|'R'|'C'|'T'
--- @field path string repo-relative path in the working tree
--- @field old_path string repo-relative path in the revision (differs on rename)
--- @field binary boolean

--- @param cmd string[]
--- @param cwd string
--- @return string? stdout nil when the command failed
local function run(cmd, cwd)
  local out = vim.system(cmd, { text = true, cwd = cwd }):wait()
  if out.code ~= 0 then
    return nil
  end
  return out.stdout
end

--- @param cwd string
--- @return string? root absolute path of the repository root
function M.root(cwd)
  local out = run({ 'git', 'rev-parse', '--show-toplevel' }, cwd)
  return out and vim.trim(out) or nil
end

--- Read a blob. `nil` means the path does not exist in that revision, which is
--- how an added file is detected.
--- @param path string
--- @param rev string
--- @param cwd string
--- @return string[]?
function M.show(path, rev, cwd)
  local out = run({ 'git', 'show', ('%s:%s'):format(rev, path) }, cwd)
  if not out then
    return nil
  end
  return vim.split((out:gsub('\n$', '')), '\n', { plain = true })
end

--- Parse `git diff --name-status -z`.
---
--- Records are NUL-separated: `M<NUL>path` for ordinary changes and
--- `R100<NUL>old<NUL>new` for renames and copies, where the number is a
--- similarity score.
---
--- @param out string
--- @return unidiff.Change[]
function M.parse_name_status(out)
  local fields = vim.split(out, '\0', { plain = true })
  local changes = {}
  local i = 1
  while i <= #fields do
    local status = fields[i]
    if status == '' then
      break
    end
    local letter = status:sub(1, 1)
    if letter == 'R' or letter == 'C' then
      changes[#changes + 1] = {
        status = letter,
        old_path = fields[i + 1],
        path = fields[i + 2],
        binary = false,
      }
      i = i + 3
    else
      changes[#changes + 1] = {
        status = letter,
        old_path = fields[i + 1],
        path = fields[i + 1],
        binary = false,
      }
      i = i + 2
    end
  end
  return changes
end

--- Parse `git diff --numstat -z` and return the paths git considers binary.
---
--- Each record is `added<TAB>deleted<TAB>path`, with `-` for both counts when
--- the file is binary. Renames leave the path field empty and follow it with
--- the old and new paths as separate records.
---
--- @param out string
--- @return table<string, true>
function M.parse_binary(out)
  local fields = vim.split(out, '\0', { plain = true })
  local binary = {}
  local i = 1
  while i <= #fields do
    local rec = fields[i]
    if rec == '' then
      break
    end
    local added, _, path = rec:match('^([^\t]*)\t([^\t]*)\t(.*)$')
    if path == '' then
      -- rename: the real paths are the next two records
      path = fields[i + 2] or fields[i + 1]
      i = i + 3
    else
      i = i + 1
    end
    if added == '-' and path then
      binary[path] = true
    end
  end
  return binary
end

--- List everything that differs between `rev` and the working tree.
--- @param rev string
--- @param cwd string
--- @return unidiff.Change[]?
function M.changed(rev, cwd)
  local status = run({ 'git', 'diff', '--name-status', '-z', '--find-renames', rev }, cwd)
  if not status then
    return nil
  end
  local changes = M.parse_name_status(status)

  local numstat = run({ 'git', 'diff', '--numstat', '-z', '--find-renames', rev }, cwd)
  if numstat then
    local binary = M.parse_binary(numstat)
    for _, c in ipairs(changes) do
      c.binary = binary[c.path] or false
    end
  end
  return changes
end

return M
