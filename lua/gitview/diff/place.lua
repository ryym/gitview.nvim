--- Finding a row of one view again in a view drawn after it.
---
--- A view is drawn into the same buffer over and over, and redrawing the same
--- file keeps the cursor on the row it was on. That is right for as long as the
--- rows stay in place, which is true of both layers shown at once: staging moves
--- a change from one layer to the other without adding or removing a row. A
--- layer shown alone loses rows to staging, and switching layers rebuilds every
--- row, so there the line has to be found again by what it is rather than where
--- it was.
local dlib = require('gitview.diff.lines')

local M = {}

--- What a row of a view is, in terms another view of the same file can be
--- searched by.
--- @class gitview.Anchor
--- @field path string the file the row belongs to
--- @field header boolean? the file's header row rather than one of its lines
--- @field side 'old'|'new'|'index'? which version the row's text is from
--- @field lnum integer? the row's number in that version
--- @field index_pos integer? where the row sits in the index
--- @field pos integer? where the row sits in the version a layer shown alone
---        leaves alone; see `held_key`
--- @field own boolean? whether `pos` is the row's own number in that version,
---        rather than the place of a row that version does not have

--- The number of a row in the version its text is from.
--- @param l gitview.Line
--- @return integer?
local function own_lnum(l)
  if l.side == 'old' then
    return l.old_lnum
  elseif l.side == 'new' then
    return l.new_lnum
  end
  return l.index_pos
end

--- Which line number of a layer shown alone stays put while it is staged from,
--- or while the index is written from outside: HEAD's for the staged layer, the
--- working tree's for the unstaged one. Neither is what staging writes, and
--- every unchanged row of the layer has it.
--- @param layer 'staged'|'unstaged'
--- @return 'old_lnum'|'new_lnum'
local function held_key(layer)
  return layer == 'staged' and 'old_lnum' or 'new_lnum'
end

--- Where a row sits in the version `key` numbers: its own number when it has
--- one, and otherwise the line after the nearest row above it that does, which
--- is the one it stands in front of.
--- @param view gitview.View
--- @param row integer
--- @param key 'old_lnum'|'new_lnum'
--- @return integer pos
--- @return boolean own
local function held_pos(view, row, key)
  local file = view.lines[row].file
  for r = row, 1, -1 do
    local l = view.lines[r]
    if l.file ~= file then
      break
    end
    if l[key] then
      return r == row and l[key] or l[key] + 1, r == row
    end
  end
  return 1, false
end

--- `held_pos` of every row of a file at once, which asking row by row would
--- cost a walk up a run of rows for each of them.
--- @param view gitview.View
--- @param rows integer[] a file's rows, in order
--- @param key 'old_lnum'|'new_lnum'
--- @return table<integer, integer> pos by row
--- @return table<integer, boolean> own by row
local function held_positions(view, rows, key)
  local pos, own = {}, {}
  local next_pos = 1
  for _, r in ipairs(rows) do
    local n = view.lines[r][key]
    if n then
      pos[r], own[r], next_pos = n, true, n + 1
    else
      pos[r], own[r] = next_pos, false
    end
  end
  return pos, own
end

--- @param view gitview.View
--- @param path string
--- @return integer? index into `view.files`
local function file_index(view, path)
  for i, f in ipairs(view.files) do
    if f.path == path then
      return i
    end
  end
  return nil
end

--- The rows of a file's lines, in order.
--- @param view gitview.View
--- @param file integer
--- @return integer[]
local function rows_of(view, file)
  local rows = {}
  for r = view.files[file].row + 1, #view.lines do
    local l = view.lines[r]
    if l.file ~= file then
      break
    end
    rows[#rows + 1] = r
  end
  return rows
end

--- The row among `rows` whose value is nearest `target`, the first of them on
--- a tie. Rows with no value are passed over.
--- @param rows integer[]
--- @param value fun(row: integer): integer?
--- @param target integer
--- @return integer?
local function nearest(rows, value, target)
  local best, best_d
  for _, r in ipairs(rows) do
    local v = value(r)
    if v then
      local d = math.abs(v - target)
      if not best_d or d < best_d then
        best, best_d = r, d
      end
    end
  end
  return best
end

--- What the row `row` of `view` is, or nil for a row of no file.
--- @param view gitview.View
--- @param row integer
--- @return gitview.Anchor?
function M.anchor(view, row)
  for _, f in ipairs(view.files) do
    if f.row == row then
      return { path = f.path, header = true }
    end
  end
  local l = view.lines[row]
  if not (l and l.file and dlib.source_kinds[l.kind]) then
    return nil
  end
  local a = {
    path = view.files[l.file].path,
    side = l.side,
    lnum = own_lnum(l),
    index_pos = l.index_pos,
  }
  if view.layer then
    a.pos, a.own = held_pos(view, row, held_key(view.layer))
  end
  return a
end

--- The file's rows and its header, or nil when `view` does not show the file.
--- @param view gitview.View
--- @param a gitview.Anchor
--- @return integer[]? rows
--- @return integer? header
local function file_of(view, a)
  local file = file_index(view, a.path)
  if not file then
    return nil, nil
  end
  return rows_of(view, file), view.files[file].row
end

--- The row of the same line in a view of the same index, which is what
--- switching layers draws: the row read from the same version at the same
--- number, or failing that, as the other layer has no such row, the one nearest
--- it in the index.
--- @param view gitview.View
--- @param a gitview.Anchor
--- @return integer?
function M.same_line(view, a)
  local rows, header = file_of(view, a)
  if not rows or a.header then
    return header
  end
  for _, r in ipairs(rows) do
    local l = view.lines[r]
    if l.side == a.side and own_lnum(l) == a.lnum then
      return r
    end
  end
  if not a.index_pos then
    return nil
  end
  return nearest(rows, function(r)
    return view.lines[r].index_pos
  end, a.index_pos)
end

--- The line number each version's rows are found by.
local LNUM_KEYS = { old = 'old_lnum', new = 'new_lnum', index = 'index_pos' }

--- The row of the same line in a view drawn any time later, with whatever may
--- have changed since: the file's contents, the layer, whitespace.
---
--- A line number alone does not follow a line that lines added or removed above
--- it have moved, so the line is looked for by its text too, at the number
--- nearest the one it had. Failing that, the row nearest that number is taken,
--- in the same version or else in the index, and a file with neither left is
--- found at its header.
--- @param view gitview.View
--- @param a gitview.Anchor
--- @param text string the line's text as it was
--- @return integer?
function M.revisit(view, a, text)
  local rows, header = file_of(view, a)
  if not rows or a.header then
    return header
  end
  local function lnum_of(r)
    local l = view.lines[r]
    return l.side == a.side and own_lnum(l) or nil
  end
  local found = nearest(rows, function(r)
    return view.lines[r].text == text and lnum_of(r) or nil
  end, a.lnum)
  if found then
    return found
  end
  local key = LNUM_KEYS[a.side]
  found = key and nearest(rows, function(r)
    return view.lines[r][key]
  end, a.lnum)
  if not found and a.index_pos then
    found = nearest(rows, function(r)
      return view.lines[r].index_pos
    end, a.index_pos)
  end
  return found or header
end

--- The row of the same line in a later view of a layer shown alone, after the
--- index has changed under it. The index's numbers have moved, so the line is
--- found by the version that has not: the row at the same number there, or
--- failing that, the one nearest it.
--- @param view gitview.View
--- @param a gitview.Anchor from a view of the same layer
--- @return integer?
function M.follow(view, a)
  local rows, header = file_of(view, a)
  if not rows or a.header then
    return header
  end
  if not (view.layer and a.pos) then
    return nil
  end
  local pos, own = held_positions(view, rows, held_key(view.layer))
  for _, r in ipairs(rows) do
    if pos[r] == a.pos and own[r] == a.own then
      return r
    end
  end
  return nearest(rows, function(r)
    return pos[r]
  end, a.pos)
end

--- Where to go once the change at `a` has been staged or unstaged from a layer
--- shown alone, which takes the rows staged out of the view: to what is left of
--- the change, or else to the next change in the file. Past the file's last
--- change, the next file's header stops the cursor rather than taking it into
--- that file's changes, where a key pressed again would act on them unseen.
---
--- nil when nothing follows, and the cursor is best left where it was: what it
--- lands on then is no change, so pressing the key again does nothing.
--- @param view gitview.View
--- @param a gitview.Anchor the first row of the change, from a view of the same layer
--- @return integer?
function M.after_change(view, a)
  local file = file_index(view, a.path)
  if not file or not (view.layer and a.pos) then
    return nil
  end
  local rows = rows_of(view, file)
  local pos = held_positions(view, rows, held_key(view.layer))
  for _, r in ipairs(rows) do
    local l = view.lines[r]
    if (l.kind == 'add' or l.kind == 'del') and pos[r] >= a.pos then
      return r
    end
  end
  local next_file = view.files[file + 1]
  return next_file and next_file.row or nil
end

return M
