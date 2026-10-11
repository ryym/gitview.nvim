--- The working tree's copy of an unmerged file, read as git left it: the merged
--- text with a conflict marked out wherever the two sides could not be merged.
---
---     <<<<<<< ours        marker
---     what HEAD has       ours
---     ||||||| base        marker, diff3 and zdiff3 only
---     what both started   base
---     =======             marker
---     what is merged in   theirs
---     >>>>>>> theirs      marker
---
--- Every line outside a conflict is `context`. Each one inside is `conflict`,
--- with `part` saying which of the above it is.
local mixed = require('gitview.diff.mixed')

local M = {}

--- Whether `text` is a marker line made of `char`. git writes seven of them,
--- followed by a label on every marker but `=======`. A file with CRLF line
--- endings keeps its `\r`, which `readfile` does not strip.
--- @param text string
--- @param char string
--- @param labelled boolean
--- @return boolean
local function is_marker(text, char, labelled)
  local rest = text:match('^' .. vim.pesc(char:rep(7)) .. '(.*)$')
  if not rest then
    return false
  end
  rest = rest:gsub('\r$', '')
  return rest == '' or (labelled and rest:sub(1, 1) == ' ')
end

--- Classify every line of `work`.
---
--- A separator counts only where it can come next in an open conflict, so that
--- a `=======` elsewhere — a heading's underline in Markdown, say — stays
--- `context`. A conflict that is never closed, such as one whose markers were
--- partly removed by hand, is left as `context` too: what it would span cannot
--- be told.
---
--- Only git's default marker size is recognised, not one changed by the
--- `conflict-marker-size` attribute.
--- @param work string[]
--- @return gitview.Line[] lines one per line of `work`, carrying `new_lnum`
---         and the `side`/`row` to look its syntax up by
--- @return integer[] starts 1-based row of the `<<<<<<<` of each conflict
function M.classify(work)
  local lines, starts = {}, {}
  -- the open conflict's first row, and the part its next line belongs to
  local open, part
  for i, text in ipairs(work) do
    local l = { text = text, kind = 'context', new_lnum = i, side = 'new', row = i - 1 }
    lines[i] = l
    if is_marker(text, '<', true) then
      -- a conflict opened before this one was never closed
      if open then
        for k = open, i - 1 do
          lines[k].kind, lines[k].part = 'context', nil
        end
      end
      open, part = i, 'ours'
      l.kind, l.part = 'conflict', 'marker'
    elseif open and part == 'ours' and is_marker(text, '|', true) then
      part = 'base'
      l.kind, l.part = 'conflict', 'marker'
    elseif open and part ~= 'theirs' and is_marker(text, '=', false) then
      part = 'theirs'
      l.kind, l.part = 'conflict', 'marker'
    elseif open and part == 'theirs' and is_marker(text, '>', true) then
      starts[#starts + 1] = open
      open, part = nil, nil
      l.kind, l.part = 'conflict', 'marker'
    elseif open then
      l.kind, l.part = 'conflict', part
    end
  end
  if open then
    for k = open, #lines do
      lines[k].kind, lines[k].part = 'context', nil
    end
  end
  return lines, starts
end

--- The lines a view of an unmerged file shows: all of the working tree's copy,
--- with what lies away from every conflict folded as an unchanged run is.
--- @param work string[]
--- @param context integer
--- @return gitview.Line[]? lines nil when `work` has no conflict marked out
--- @return integer[] hunk_rows the first row of each conflict
function M.build(work, context)
  local lines, starts = M.classify(work)
  if #starts == 0 then
    return nil, {}
  end
  -- `fold`'s own rows would make one of two conflicts with nothing between them.
  return (mixed.fold(lines, context)), starts
end

return M
