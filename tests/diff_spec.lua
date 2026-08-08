local dlib = require('unidiff.diff')

local test, eq = _G.test, _G.eq

--- Render a view as compact strings so expectations stay readable.
--- @param lines unidiff.Line[]
--- @return string[]
local function dump(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = ('%s%s|%s|%s'):format(
      ({ add = '+', del = '-', context = ' ' })[l.kind],
      l.text,
      l.old_lnum or '',
      l.new_lnum or ''
    )
  end
  return out
end

--- @param old string[]
--- @param new string[]
--- @param context integer?
local function run(old, new, context)
  local hunks = dlib.hunks(old, new)
  return dlib.build(hunks, old, new, context or 1)
end

test('pure insertion keeps every old line as context', function()
  local lines = run({ 'a', 'b', 'c' }, { 'a', 'X', 'b', 'c' }, 3)
  eq({ ' a|1|1', '+X||2', ' b|2|3', ' c|3|4' }, dump(lines))
end)

test('pure deletion keeps surrounding context', function()
  local lines = run({ 'a', 'b', 'c' }, { 'a', 'c' })
  eq({ ' a|1|1', '-b|2|', ' c|3|2' }, dump(lines))
end)

test('insertion at the very start', function()
  local lines = run({ 'a', 'b' }, { 'X', 'a', 'b' }, 3)
  eq({ '+X||1', ' a|1|2', ' b|2|3' }, dump(lines))
end)

test('insertion at the very end', function()
  local lines = run({ 'a', 'b' }, { 'a', 'b', 'X' })
  eq({ ' b|2|2', '+X||3' }, dump(lines))
end)

test('deletion of the whole file', function()
  local lines = run({ 'a', 'b' }, {})
  eq({ '-a|1|', '-b|2|' }, dump(lines))
end)

test('change block reports del lines before add lines', function()
  local lines = run({ 'a', 'b', 'c' }, { 'a', 'B', 'c' })
  eq({ ' a|1|1', '-b|2|', '+B||2', ' c|3|3' }, dump(lines))
end)

test('no line is emitted twice when hunks are close together', function()
  -- context=3 would make the two hunks' context ranges overlap the other hunk
  local old = { '1', '2', '3', '4', '5', '6', '7', '8' }
  local new = { '1', 'x', '3', '4', '5', '6', 'y', '8' }
  local lines = run(old, new, 3)
  local seen_old, seen_new = {}, {}
  for _, l in ipairs(lines) do
    if l.old_lnum then
      assert(not seen_old[l.old_lnum], 'old line ' .. l.old_lnum .. ' emitted twice')
      seen_old[l.old_lnum] = true
    end
    if l.new_lnum then
      assert(not seen_new[l.new_lnum], 'new line ' .. l.new_lnum .. ' emitted twice')
      seen_new[l.new_lnum] = true
    end
  end
end)

test('line numbers stay monotonic across several hunks', function()
  local old, new = {}, {}
  for i = 1, 60 do
    old[i] = 'line ' .. i
    new[i] = (i % 7 == 0) and ('changed ' .. i) or ('line ' .. i)
  end
  local lines = run(old, new, 3)
  local last_old, last_new = 0, 0
  for _, l in ipairs(lines) do
    if l.old_lnum then
      assert(l.old_lnum > last_old, 'old lnum not increasing')
      last_old = l.old_lnum
    end
    if l.new_lnum then
      assert(l.new_lnum > last_new, 'new lnum not increasing')
      last_new = l.new_lnum
    end
  end
end)

test('context lines carry the text of the matching new line', function()
  local old = { 'a', 'b', 'c', 'd' }
  local new = { 'a', 'B', 'c', 'd' }
  local lines = run(old, new, 3)
  for _, l in ipairs(lines) do
    if l.kind == 'context' then
      eq(new[l.new_lnum], l.text, 'context text must match the new version too')
    end
  end
end)

test('gaps report how many lines were skipped', function()
  local old, new = {}, {}
  for i = 1, 30 do
    old[i], new[i] = 'line ' .. i, 'line ' .. i
  end
  new[15] = 'changed'
  local lines, hunk_rows, gaps = dlib.build(dlib.hunks(old, new), old, new, 3)
  eq(1, #hunk_rows)
  eq(2, #gaps)
  -- 11 lines before the leading context, 12 after the trailing one
  eq(11, gaps[1].count)
  eq(12, gaps[2].count)
  eq(#lines + 1, gaps[2].row)
end)

test('change_pairs only pairs equally sized blocks', function()
  local lines = {
    { kind = 'del' },
    { kind = 'del' },
    { kind = 'add' },
    { kind = 'add' },
    { kind = 'context' },
    { kind = 'del' },
    { kind = 'add' },
    { kind = 'add' },
  }
  eq({ { 1, 3 }, { 2, 4 } }, dlib.change_pairs(lines))
end)

test('trailing newline differences do not produce phantom hunks', function()
  eq({}, dlib.hunks({ 'a', 'b' }, { 'a', 'b' }))
end)

test('hunks match git diff by default', function()
  -- `git diff -U0` on this pair reports exactly one hunk, `@@ -3 +3,2 @@`.
  eq({ { 3, 1, 3, 2 } }, dlib.hunks({ 'a', 'b', 'c', 'd', 'e' }, { 'a', 'b', 'X', 'Y', 'd', 'e' }))
end)

test('linematch is opt-in because it disagrees with git', function()
  -- It re-pairs lines inside the hunk and splits it into "insert X" plus
  -- "c -> Y", which reorders what the unified view shows.
  local hunks =
    dlib.hunks({ 'a', 'b', 'c', 'd', 'e' }, { 'a', 'b', 'X', 'Y', 'd', 'e' }, { linematch = 60 })
  eq({ { 2, 0, 3, 1 }, { 3, 1, 4, 1 } }, hunks)
end)
