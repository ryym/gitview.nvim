local dlib = require('gitview.diff.lines')

local test, eq = _G.test, _G.eq

--- Render a view as compact strings so expectations stay readable.
--- @param lines gitview.Line[]
--- @return string[]
local function dump(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = ('%s%s|%s|%s'):format(
      l.folded and '~' or ({ add = '+', del = '-', context = ' ' })[l.kind],
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
  -- 'a' is out of context, but hiding it would cost a separator row anyway
  eq({ ' a|1|1', ' b|2|2', '+X||3' }, dump(lines))
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

test('unchanged ranges away from a change are folded, not dropped', function()
  local old, new = {}, {}
  for i = 1, 30 do
    old[i], new[i] = 'line ' .. i, 'line ' .. i
  end
  new[15] = 'changed'
  local lines, hunk_rows = dlib.build(dlib.hunks(old, new), old, new, 3)
  eq(1, #hunk_rows)
  -- every line of the file, with line 15 shown twice
  eq(31, #lines)
  local folded = {}
  for i, l in ipairs(lines) do
    if l.folded then
      folded[#folded + 1] = i
    end
  end
  -- 11 lines before the leading context, 12 after the trailing one
  eq(vim.list_extend(vim.fn.range(1, 11), vim.fn.range(20, 31)), folded)
end)

test('a range of one line is left open rather than folded', function()
  -- a closed fold takes a row of its own, so folding one line away saves none
  local old, new = {}, {}
  for i = 1, 6 do
    old[i], new[i] = 'line ' .. i, 'line ' .. i
  end
  new[5] = 'changed'
  local lines = dlib.build(dlib.hunks(old, new), old, new, 3)
  for _, l in ipairs(lines) do
    eq(nil, l.folded, 'nothing should be folded')
  end
  eq(7, #lines, 'all six lines, with line 5 shown twice')
end)

--- @param kinds_texts [string, string, integer?][] kind, text and file of each line
--- @return gitview.Line[]
local function change_lines(kinds_texts)
  return vim.tbl_map(function(t)
    return { kind = t[1], text = t[2], file = t[3] }
  end, kinds_texts)
end

test('change_pairs pairs similar lines of an equally sized block', function()
  local lines = change_lines({
    { 'del', 'local a = 1' },
    { 'del', 'local b = 2' },
    { 'add', 'local a = 10' },
    { 'add', 'local b = 20' },
  })
  eq({ { 1, 3 }, { 2, 4 } }, dlib.change_pairs(lines))
end)

test('change_pairs pairs around an addition inserted into the block', function()
  -- Pairing by position would set `local b = 2` against the inserted line.
  local lines = change_lines({
    { 'del', 'local a = 1' },
    { 'del', 'local b = 2' },
    { 'add', 'local a = 10' },
    { 'add', 'print("inserted")' },
    { 'add', 'local b = 20' },
  })
  eq({ { 1, 3 }, { 2, 5 } }, dlib.change_pairs(lines))
end)

test('change_pairs leaves a deletion unpaired when no addition resembles it', function()
  local lines = change_lines({
    { 'del', 'local a = 1' },
    { 'del', 'print("removed")' },
    { 'del', 'local b = 2' },
    { 'add', 'local a = 10' },
    { 'add', 'local b = 20' },
  })
  eq({ { 1, 4 }, { 3, 5 } }, dlib.change_pairs(lines))
end)

test('change_pairs keeps pairs in order', function()
  -- The second deletion resembles the first addition, but pairing them would
  -- cross the first pair; a unified view cannot show crossing pairs as changes.
  local lines = change_lines({
    { 'del', 'return total' },
    { 'del', 'local count = 0' },
    { 'add', 'local count = 1' },
    { 'add', 'return total + 1' },
  })
  eq({ { 1, 4 } }, dlib.change_pairs(lines))
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

test('change_pairs does not pair across a file boundary', function()
  -- One file's trailing deletions sit directly above the next file's additions.
  local lines = change_lines({
    { 'del', 'local a = 1', 1 },
    { 'add', 'local a = 10', 2 },
    { 'add', 'local a = 10', 2 },
  })
  eq({}, dlib.change_pairs(lines))
end)

test('change_pairs still pairs within one file', function()
  local lines = change_lines({
    { 'del', 'local a = 1', 1 },
    { 'add', 'local a = 10', 1 },
    { 'del', 'local b = 2', 2 },
    { 'add', 'local b = 20', 2 },
  })
  eq({ { 1, 2 }, { 3, 4 } }, dlib.change_pairs(lines))
end)

-- `vim.diff`'s own option, the equivalent of `git diff -w`. It has to be
-- forwarded explicitly: the options table is built key by key.
test('ignoring whitespace drops a hunk that is only whitespace', function()
  local old = { 'one', 'two', 'three' }
  local new = { 'one', '  two  ', 'three' }
  eq(1, #dlib.hunks(old, new))
  eq(0, #dlib.hunks(old, new, { ignore_whitespace = true }))
end)

test('ignoring whitespace keeps a hunk that is not', function()
  local old = { 'one', 'two' }
  local new = { 'one', '  TWO  ' }
  eq(1, #dlib.hunks(old, new, { ignore_whitespace = true }))
end)
