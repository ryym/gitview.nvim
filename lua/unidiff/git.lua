local M = {}

--- @class unidiff.Change
--- @field status 'A'|'M'|'D'|'R'|'C'|'T'
--- @field path string repo-relative path in the working tree
--- @field old_path string repo-relative path in the revision (differs on rename)
--- @field binary boolean

--- Split blob contents into lines. An empty blob is an empty file, so it has no
--- lines at all; `vim.split` would otherwise report a single empty one and the
--- diff would show a phantom line.
--- @param text string
--- @return string[]
local function blob_lines(text)
  if text == '' then
    return {}
  end
  return vim.split((text:gsub('\n$', '')), '\n', { plain = true })
end

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
  return blob_lines(out)
end

--- Parse the stream `git cat-file --batch` writes.
---
--- Each object is a header line `<sha> <type> <size>` followed by exactly
--- `size` bytes and a newline; a spec that resolves to nothing yields
--- `<spec> missing` instead. Objects come back in the order they were asked
--- for, so results are matched by position rather than by parsing the spec back
--- out of the header.
---
--- @param out string raw stdout, which must not have been newline-converted
--- @return (string[]|false)[]
function M.parse_batch(out)
  local results = {}
  local pos = 1
  while pos <= #out do
    local nl = out:find('\n', pos, true)
    if not nl then
      break
    end
    local header = out:sub(pos, nl - 1)
    local size = header:match('^%x+ %w+ (%d+)$')
    if size then
      local body = out:sub(nl + 1, nl + tonumber(size))
      results[#results + 1] = blob_lines(body)
      pos = nl + 1 + tonumber(size) + 1 -- content, then its trailing newline
    else
      -- `<spec> missing`, or anything else we cannot make sense of
      results[#results + 1] = false
      pos = nl + 1
    end
  end
  return results
end

--- Read many blobs with one `git cat-file` rather than one `git show` each.
--- Spawning a process per file dominates the cost of a large diff.
---
--- @param specs string[] revision specs, e.g. `HEAD:src/init.lua`
--- @param cwd string
--- @return (string[]|false)[] contents per spec, `false` when it does not exist
function M.batch_show(specs, cwd)
  if #specs == 0 then
    return {}
  end
  -- `text = true` would rewrite CRLF and desynchronise the byte counts in the
  -- headers, so the stream is read raw.
  local out = vim.system({ 'git', 'cat-file', '--batch' }, {
    cwd = cwd,
    stdin = table.concat(specs, '\n') .. '\n',
  }):wait()
  if out.code ~= 0 then
    return {}
  end
  return M.parse_batch(out.stdout)
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

--- @param args string[] what to compare, as passed to `git diff`
--- @param cwd string
--- @return unidiff.Change[]?
local function diff_changes(args, cwd)
  local function git_diff(format)
    return run(vim.list_extend({ 'git', 'diff', format, '-z', '--find-renames' }, args), cwd)
  end
  local status = git_diff('--name-status')
  if not status then
    return nil
  end
  local changes = M.parse_name_status(status)

  local numstat = git_diff('--numstat')
  if numstat then
    local binary = M.parse_binary(numstat)
    for _, c in ipairs(changes) do
      c.binary = binary[c.path] or false
    end
  end
  return changes
end

--- List everything that differs between `rev` and the working tree.
--- @param rev string
--- @param cwd string
--- @return unidiff.Change[]?
function M.changed(rev, cwd)
  return diff_changes({ rev }, cwd)
end

--- List everything that differs between HEAD and the index.
--- @param cwd string
--- @return unidiff.Change[]?
function M.changed_staged(cwd)
  return diff_changes({ '--cached' }, cwd)
end

--- List everything that differs between the index and the working tree.
--- @param cwd string
--- @return unidiff.Change[]?
function M.changed_unstaged(cwd)
  return diff_changes({}, cwd)
end

return M
