--- Which files of a review have been checked off as read.
---
--- A check is kept by path, the new side's for a rename, and only for as long
--- as the review lasts. Nothing here reads git or the editor: the session hands
--- in the paths it lists.
local M = {}

--- @class gitview.Check a file checked off as read

--- @alias gitview.CheckState 'checked'
---| nil not checked

--- @param checks table<string, gitview.Check>
--- @param path string
--- @return gitview.CheckState
function M.state(checks, path)
  return checks[path] and 'checked' or nil
end

--- Whether a file is still to be read.
--- @param checks table<string, gitview.Check>
--- @param path string
--- @return boolean
function M.is_open(checks, path)
  return M.state(checks, path) ~= 'checked'
end

--- Check every path off, or, when every one is checked already, take the
--- checks off them all. The paths go one way together, as the files of a
--- directory do when it is staged.
--- @param checks table<string, gitview.Check> changed in place
--- @param paths string[]
--- @return boolean checked whether they were checked rather than taken off
function M.toggle(checks, paths)
  local all = true
  for _, path in ipairs(paths) do
    if M.is_open(checks, path) then
      all = false
      break
    end
  end
  for _, path in ipairs(paths) do
    checks[path] = not all and {} or nil
  end
  return not all
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
