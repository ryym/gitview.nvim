local mixed = require('unidiff.diff.mixed')

local test, eq = _G.test, _G.eq

local STAGE = { staged = 'S', unstaged = ' ', index = 'I' }

--- `<kind><stage><text>|<head lnum>|<work lnum>`
--- @param lines unidiff.Line[]
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
  local dlib = require('unidiff.diff.lines')
  -- a staged deletion followed by an unstaged addition is two changes
  eq({}, dlib.change_pairs(mixed.merge({ 'x' }, {}, { 'y' })))
  -- each layer of a partially staged hunk pairs on its own
  eq({ { 1, 2 }, { 3, 4 } }, dlib.change_pairs(mixed.merge({ 'a', 'b' }, { 'a', 'B' }, { 'A', 'B' })))
end)

--- `index_pos` is what an index-based patch would be stated in terms of, so it
--- is asserted separately from the display columns above.
--- @param lines unidiff.Line[]
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
