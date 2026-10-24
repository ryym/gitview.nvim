--- Which files of a review have been checked off as read, and which have
--- changed since.
---
--- A check is kept by path, the new side's for a rename and the old side's for
--- a deletion, and only for as long as the review lasts. It records what was
--- read rather than that something was, so that a file changed afterwards is
--- told apart from one still as it was read.
local source = require('gitview.diff.source')

local M = {}

--- @class gitview.Check a file checked off as read
--- @field hash string? what was read, as `hash_lines` or `hash_file` give it;
---        nil in a range between commits, which cannot change
--- @field now string? what the file was last seen to be, the same way
--- @field binary boolean? read as bytes rather than lines

--- @alias gitview.CheckState 'checked'
---| 'changed' checked, and different now from what was read
---| nil not checked

--- What a deleted file is recorded as, which no hash can be mistaken for.
M.DELETED = 'deleted'

--- @param checks table<string, gitview.Check>
--- @param path string
--- @return gitview.CheckState
function M.state(checks, path)
  local c = checks[path]
  if not c then
    return nil
  end
  if c.hash and c.now and c.now ~= c.hash then
    return 'changed'
  end
  return 'checked'
end

--- Whether a file is still to be read: not checked, or changed since.
--- @param checks table<string, gitview.Check>
--- @param path string
--- @return boolean
function M.is_open(checks, path)
  return M.state(checks, path) ~= 'checked'
end

--- Check every path off, or, when every one is checked already, take the
--- checks off them all. The paths go one way together, as the files of a
--- directory do when it is staged. A file changed since it was checked is
--- checked again, as what it is now.
--- @param checks table<string, gitview.Check> changed in place
--- @param paths string[]
--- @param read? table<string, {hash:string, binary:boolean?}> what each path
---        was read as; nil in a range between commits
--- @return boolean checked whether they were checked rather than taken off
function M.toggle(checks, paths, read)
  local all = true
  for _, path in ipairs(paths) do
    if M.is_open(checks, path) then
      all = false
      break
    end
  end
  for _, path in ipairs(paths) do
    local r = read and read[path]
    checks[path] = not all and { hash = r and r.hash, now = r and r.hash, binary = r and r.binary }
      or nil
  end
  return not all
end

--- What a version of a file comes to, read as lines.
---
--- Lines rather than bytes, since lines are what a view is built from and what
--- was read is what a check records. A final newline is not told apart from
--- none, as the view cannot show the difference either.
--- @param lines string[]
--- @return string
function M.hash_lines(lines)
  return vim.fn.sha256(table.concat(lines, '\n'))
end

--- What a file in the working tree comes to now: read as a view of it would
--- read it, or as bytes for a binary file, which a view has no lines of.
--- @param path string absolute
--- @param binary boolean?
--- @return string
function M.hash_file(path, binary)
  if vim.fn.filereadable(path) == 0 then
    return M.DELETED
  end
  if not binary then
    return M.hash_lines(source.working_lines(path))
  end
  local f = io.open(path, 'rb')
  if not f then
    return M.DELETED
  end
  local bytes = f:read('a')
  f:close()
  return vim.fn.sha256(bytes)
end

--- Note what a checked file is now, as `hash_lines` or `hash_file` gives it.
--- @param checks table<string, gitview.Check>
--- @param path string
--- @param hash string
--- @return boolean moved whether its state changed
function M.see(checks, path, hash)
  local c = checks[path]
  if not c or not c.hash then
    return false
  end
  local was = M.state(checks, path)
  c.now = hash
  return M.state(checks, path) ~= was
end

--- How far a review has got through its files.
--- @param checks table<string, gitview.Check>
--- @param paths string[] the files it lists
--- @return integer checked
function M.progress(checks, paths)
  local checked = 0
  for _, path in ipairs(paths) do
    if M.state(checks, path) == 'checked' then
      checked = checked + 1
    end
  end
  return checked
end

--- Whether every file listed is checked.
--- @param checks table<string, gitview.Check>
--- @param paths string[]
--- @return boolean
function M.is_done(checks, paths)
  return M.progress(checks, paths) == #paths
end

--- The next file still to be read from `from` in `dir`, going round from the
--- other end when there is none that way: files are not always checked off in
--- order. `from` itself comes last, if it is still to be read.
--- @param checks table<string, gitview.Check>
--- @param paths string[]
--- @param from integer index into `paths`; 0 to start before the first, or
---        `#paths + 1` after the last
--- @param dir 1|-1
--- @return integer? index nil when every file is checked
function M.next_open(checks, paths, from, dir)
  local n = #paths
  for step = 1, n do
    local i = (from - 1 + dir * step) % n + 1
    if M.is_open(checks, paths[i]) then
      return i
    end
  end
  return nil
end

return M
