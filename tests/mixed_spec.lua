local mixed = require('gitview.diff.mixed')

local test, eq = _G.test, _G.eq

local STAGE = { staged = 'S', unstaged = ' ', index = 'I' }

--- `<kind><stage><text>|<head lnum>|<work lnum>`
--- @param lines gitview.Line[]
--- @return string[]
local function dump(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = ('%s%s%s|%s|%s'):format(
      l.folded and '~' or ({ add = '+', del = '-', context = ' ' })[l.kind],
      l.stage and STAGE[l.stage] or ' ',
      l.text,
      l.old_lnum or '',
      l.new_lnum or ''
    )
  end
  return out
end

test('mixed: a fully staged change is marked staged', function()
  local lines = mixed.merge({ 'a', 'b' }, { 'a', 'B' }, { 'a', 'B' })
  eq({ '  a|1|1', '-Sb|2|', '+SB||2' }, dump(lines))
end)

test('mixed: an unstaged change is marked unstaged', function()
  local lines = mixed.merge({ 'a', 'b' }, { 'a', 'b' }, { 'a', 'B' })
  eq({ '  a|1|1', '- b|2|', '+ B||2' }, dump(lines))
end)

-- The ordering rule in merge: without it the working-tree addition of the first
-- change lands after the staged deletion of the second, interleaving both.
test('mixed: a partially staged hunk keeps each change together', function()
  local lines = mixed.merge({ 'a', 'b' }, { 'a', 'B' }, { 'A', 'B' })
  eq({ '- a|1|', '+ A||1', '-Sb|2|', '+SB||2' }, dump(lines))
end)

test('mixed: deletion comes first when nothing is replaced', function()
  local lines = mixed.merge({ 'x' }, {}, { 'y' })
  eq({ '-Sx|1|', '+ y||1' }, dump(lines))
end)

test('mixed: a staged line changed again shows all three versions', function()
  local lines = mixed.merge({ 'x' }, { 'X' }, { 'XX' })
  eq({ '-Sx|1|', '-IX||', '+ XX||1' }, dump(lines))
end)

test('mixed: a staged change reverted in the working tree is still shown', function()
  local lines = mixed.merge({ 'a', 'b' }, { 'a', 'B' }, { 'a', 'b' })
  eq({ '  a|1|1', '-Sb|2|', '-IB||', '+ b||2' }, dump(lines))
end)

test('mixed: index lines carry both line numbers across offsets', function()
  local lines = mixed.merge({ 'a', 'c' }, { 'a', 'b', 'c' }, { 'z', 'a', 'b', 'c' })
  eq({ '+ z||1', '  a|1|2', '+Sb||3', '  c|2|4' }, dump(lines))
end)

test('mixed: build folds unchanged runs and reports hunk rows', function()
  local head = { '1', '2', '3', '4', '5', '6', '7', '8', '9' }
  local index = vim.deepcopy(head)
  index[2] = 'two'
  local work = vim.deepcopy(index)
  work[8] = 'eight'
  local lines, hunk_rows = mixed.build(head, index, work, 1)
  eq({
    '  1|1|1',
    '-S2|2|',
    '+Stwo||2',
    '  3|3|3',
    '~ 4|4|4',
    '~ 5|5|5',
    '~ 6|6|6',
    '  7|7|7',
    '- 8|8|',
    '+ eight||8',
    '  9|9|9',
  }, dump(lines))
  eq({ 2, 9 }, hunk_rows)
end)

test('mixed: build returns nil when nothing differs', function()
  eq(nil, (mixed.build({ 'a' }, { 'a' }, { 'a' }, 3)))
end)

test('mixed: word-level pairing does not cross a stage boundary', function()
  local dlib = require('gitview.diff.lines')
  -- a staged deletion followed by an unstaged addition is two changes
  eq({}, dlib.change_pairs(mixed.merge({ 'x = 1' }, {}, { 'x = 2' })))
  -- each layer of a partially staged hunk pairs on its own
  local head, index, work = { 'x = 1', 'y = 2' }, { 'x = 1', 'y = 3' }, { 'x = 4', 'y = 3' }
  eq({ { 1, 2 }, { 3, 4 } }, dlib.change_pairs(mixed.merge(head, index, work)))
end)

--- `index_pos` is what an index-based patch would be stated in terms of, so it
--- is asserted separately from the display columns above.
--- @param lines gitview.Line[]
--- @return string[]
local function dump_index(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = ('%s%s|%s|%s'):format(
      ({ add = '+', del = '-', context = ' ' })[l.kind],
      l.text,
      l.side,
      l.index_pos or ''
    )
  end
  return out
end

test('mixed: every row is placed against the index', function()
  -- `b` is in HEAD only and `B` in index and work, so the pair sits in front of
  -- index line 2 and at index line 2 respectively.
  local lines = mixed.merge({ 'a', 'b' }, { 'a', 'B' }, { 'a', 'B' })
  eq({ ' a|index|1', '-b|old|2', '+B|index|2' }, dump_index(lines))
end)

test('mixed: a row past the last index line is placed one past the end', function()
  local lines = mixed.merge({ 'a' }, { 'a' }, { 'a', 'z' })
  eq({ ' a|index|1', '+z|new|2' }, dump_index(lines))
end)

test('mixed: an index-only line keeps its own index line number', function()
  -- staged addition of `x`, then removed from the working tree again
  local lines = mixed.merge({}, { 'x' }, {})
  eq({ '-x|index|1' }, dump_index(lines))
end)

--- The rows of `merge` as `layer` alone shows them, dumped as above.
--- @param head string[]
--- @param index string[]
--- @param work string[]
--- @param layer gitview.Layer
--- @return string[]
local function dump_layer(head, index, work, layer)
  return dump(mixed.project(mixed.merge(head, index, work), layer))
end

test('mixed: one layer alone turns the other into context or drops it', function()
  -- partially staged: `a -> A` unstaged, `b -> B` staged
  local head, index, work = { 'a', 'b' }, { 'a', 'B' }, { 'A', 'B' }
  eq({ '  a|1|', '-Sb|2|', '+SB||2' }, dump_layer(head, index, work, 'staged'))
  eq({ '- a|1|', '+ A||1', '  B||2' }, dump_layer(head, index, work, 'unstaged'))
end)

test('mixed: an index-only line is an addition staged and a deletion unstaged', function()
  -- `B` staged, then reverted in the working tree
  local head, index, work = { 'a', 'b' }, { 'a', 'B' }, { 'a', 'b' }
  eq({ '  a|1|1', '-Sb|2|', '+SB||' }, dump_layer(head, index, work, 'staged'))
  eq({ '  a|1|1', '- B||', '+ b||2' }, dump_layer(head, index, work, 'unstaged'))
end)

test('mixed: both layers leave the rows as merged', function()
  local head, index, work = { 'a', 'b' }, { 'a', 'B' }, { 'a', 'b' }
  eq(dump(mixed.merge(head, index, work)), dump_layer(head, index, work, 'both'))
end)

-- A layer alone is meant to read as the plain diff of the two versions it
-- compares, so the rows are checked against that diff built directly.
test('mixed: one layer alone is the plain diff of its two versions', function()
  local dlib = require('gitview.diff.lines')
  local function rows(lines)
    local out = {}
    for _, l in ipairs(lines) do
      out[#out + 1] = ({ add = '+', del = '-', context = ' ' })[l.kind] .. l.text
    end
    return out
  end
  local function plain(old, new)
    return rows(dlib.build(dlib.hunks(old, new), old, new, math.huge))
  end
  local cases = {
    { { 'a', 'b' }, { 'a', 'B' }, { 'A', 'B' } },
    { { 'x' }, { 'X' }, { 'XX' } },
    { { 'a', 'b', 'c', 'd' }, { 'a', 'c', 'd', 'e' }, { 'z', 'a', 'c', 'D', 'e' } },
    { { 'a', 'b' }, { 'a', 'B' }, { 'a', 'b' } },
    { {}, { 'x', 'y' }, { 'y', 'z' } },
  }
  for _, c in ipairs(cases) do
    local head, index, work = c[1], c[2], c[3]
    eq(plain(head, index), rows(mixed.project(mixed.merge(head, index, work), 'staged')))
    eq(plain(index, work), rows(mixed.project(mixed.merge(head, index, work), 'unstaged')))
  end
end)

test('mixed: build returns nil when the layer shown has no change', function()
  eq(nil, (mixed.build({ 'a' }, { 'a' }, { 'A' }, 3, { layer = 'staged' })))
  eq(nil, (mixed.build({ 'a' }, { 'A' }, { 'A' }, 3, { layer = 'unstaged' })))
end)

test('mixed: words pair within the one layer shown', function()
  local dlib = require('gitview.diff.lines')
  local head, index, work = { 'x = 1' }, { 'x = 2' }, { 'x = 3' }
  -- the index line pairs with HEAD's when staged and the working tree's when not
  eq({ { 1, 2 } }, dlib.change_pairs(mixed.project(mixed.merge(head, index, work), 'staged')))
  eq({ { 1, 2 } }, dlib.change_pairs(mixed.project(mixed.merge(head, index, work), 'unstaged')))
end)
