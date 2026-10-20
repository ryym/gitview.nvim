local place = require('gitview.diff.place')
local vlib = require('gitview.diff.view')

local test, eq = _G.test, _G.eq

--- A view of mixed sources, each `{ path, head, index, work }`, with `layer` shown.
--- @param files [string, string[], string[], string[]][]
--- @param layer gitview.Layer
--- @return gitview.View
local function view_of(files, layer)
  local sources = {}
  for i, f in ipairs(files) do
    sources[i] = {
      label = f[1],
      path = '/repo/' .. f[1],
      ft = 'text',
      old_lines = f[2],
      index_lines = f[3],
      new_lines = f[4],
    }
  end
  local opts = { algorithm = 'histogram', linematch = 0, layer = layer }
  return assert(vlib.build(sources, 'x', 99, opts))
end

--- @param view gitview.View
--- @param row integer?
--- @return string?
local function text_at(view, row)
  local l = row and view.lines[row]
  return l and ('%s %s'):format(l.kind, l.text) or nil
end

--- @param view gitview.View
--- @param text string
--- @return integer
local function row_of(view, text)
  for r, l in ipairs(view.lines) do
    if l.file and l.text == text then
      return r
    end
  end
  error('no row ' .. text)
end

-- `w` is only in the working tree, so the staged layer has no row for it.
test('place: a line another layer lacks lands on its neighbour in the index', function()
  local f = { 'f.txt', { 'a', 'b' }, { 'a', 'B' }, { 'a', 'w', 'B' } }
  local both = view_of({ f }, 'both')
  local staged = view_of({ f }, 'staged')
  local at = place.same_line(staged, assert(place.anchor(both, row_of(both, 'w'))))
  eq('del b', text_at(staged, at))
end)

test("place: past a file's last change the next file's header stops the cursor", function()
  local head = { 'a', 'k', 'b' }
  local g = { 'g.txt', { 'x' }, { 'x' }, { 'X' } }
  local before = view_of({ { 'f.txt', head, head, { 'A', 'k', 'B' } }, g }, 'unstaged')
  local anchor = assert(place.anchor(before, row_of(before, 'b')))
  -- the second change of `f.txt` staged away, the first left above it
  local after = view_of({ { 'f.txt', head, { 'a', 'k', 'B' }, { 'A', 'k', 'B' } }, g }, 'unstaged')
  eq(after.files[2].row, place.after_change(after, anchor))
end)

test('place: a header is found again as the same file\'s header', function()
  local f = { 'f.txt', { 'a' }, { 'a' }, { 'A' } }
  local g = { 'g.txt', { 'x' }, { 'x' }, { 'X' } }
  local before = view_of({ f, g }, 'both')
  local after = view_of({ g }, 'unstaged')
  eq(after.files[1].row, place.same_line(after, assert(place.anchor(before, before.files[2].row))))
end)
