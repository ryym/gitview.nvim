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

--- @class unidiff.GitResult
--- @field ok boolean
--- @field stdout string
--- @field stderr string what to show the user when `ok` is false
--- @field code integer

--- Every subprocess goes through here, so that stderr is never thrown away and
--- so that making these calls asynchronous later is one change rather than many.
---
--- @param cmd string[]
--- @param cwd string
--- @param opts? table extra `vim.system` options; `text = false` reads stdout raw
--- @return unidiff.GitResult
function M.run(cmd, cwd, opts)
  local sys = vim.tbl_extend('force', { text = true, cwd = cwd }, opts or {})
  local out = vim.system(cmd, sys):wait()
  return {
    ok = out.code == 0,
    stdout = out.stdout or '',
    stderr = vim.trim(out.stderr or ''),
    code = out.code,
  }
end

--- @param cwd string
--- @return string? root absolute path of the repository root
function M.root(cwd)
  local res = M.run({ 'git', 'rev-parse', '--show-toplevel' }, cwd)
  return res.ok and vim.trim(res.stdout) or nil
end

--- Read a blob. `nil` means the path does not exist in that revision, which is
--- how an added file is detected.
--- @param path string
--- @param rev string
--- @param cwd string
--- @return string[]?
function M.show(path, rev, cwd)
  local res = M.run({ 'git', 'show', ('%s:%s'):format(rev, path) }, cwd)
  if not res.ok then
    return nil
  end
  return blob_lines(res.stdout)
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
  local res = M.run({ 'git', 'cat-file', '--batch' }, cwd, {
    text = false,
    stdin = table.concat(specs, '\n') .. '\n',
  })
  if not res.ok then
    return {}
  end
  return M.parse_batch(res.stdout)
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

--- Split the NUL-separated path list `-z` produces.
---
--- The stream ends with a separator rather than delimiting between paths, so
--- the final field is empty and is dropped. A path may contain anything but
--- NUL, which is the whole reason for asking for this format.
---
--- @param out string
--- @return string[]
function M.parse_paths(out)
  local paths = {}
  for _, path in ipairs(vim.split(out, '\0', { plain = true })) do
    if path ~= '' then
      paths[#paths + 1] = path
    end
  end
  return paths
end

--- @param args string[] what to compare, as passed to `git diff`
--- @param cwd string
--- @return unidiff.Change[]? changes
--- @return string? err why the command failed
local function diff_changes(args, cwd)
  local function git_diff(format)
    return M.run(vim.list_extend({ 'git', 'diff', format, '-z', '--find-renames' }, args), cwd)
  end
  local status = git_diff('--name-status')
  if not status.ok then
    return nil, status.stderr
  end
  local changes = M.parse_name_status(status.stdout)

  -- A failure here only costs the binary flags, so the listing is still useful.
  local numstat = git_diff('--numstat')
  if numstat.ok then
    local binary = M.parse_binary(numstat.stdout)
    for _, c in ipairs(changes) do
      c.binary = binary[c.path] or false
    end
  end
  return changes
end

--- List everything that differs between `rev` and the working tree.
--- @param rev string
--- @param cwd string
--- @return unidiff.Change[]? changes
--- @return string? err
function M.changed(rev, cwd)
  return diff_changes({ rev }, cwd)
end

--- List everything that differs between HEAD and the index.
--- @param cwd string
--- @return unidiff.Change[]? changes
--- @return string? err
function M.changed_staged(cwd)
  return diff_changes({ '--cached' }, cwd)
end

--- List everything that differs between the index and the working tree.
--- @param cwd string
--- @return unidiff.Change[]? changes
--- @return string? err
function M.changed_unstaged(cwd)
  return diff_changes({}, cwd)
end

--- Files git is not tracking and has not been told to ignore.
---
--- `git diff` never reports these, so they are the one part of the working tree
--- that has to be asked for separately.
---
--- @param cwd string the repository root; paths come back relative to it
--- @return string[]? paths
--- @return string? err
function M.untracked(cwd)
  local res = M.run({ 'git', 'ls-files', '--others', '--exclude-standard', '-z' }, cwd)
  if not res.ok then
    return nil, res.stderr
  end
  return M.parse_paths(res.stdout)
end

return M
