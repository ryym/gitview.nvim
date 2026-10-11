local conflict = require('gitview.diff.conflict')

local test, eq = _G.test, _G.eq

local MARK = { marker = '!', ours = '<', base = '|', theirs = '>' }

--- `<part><text>|<lnum>`, with ` ` for a line outside every conflict and `~`
--- for one folded away.
--- @param lines gitview.Line[]
--- @return string[]
local function dump(lines)
  local out = {}
  for i, l in ipairs(lines) do
    local mark = l.kind == 'conflict' and MARK[l.part] or ' '
    out[i] = ('%s%s|%d'):format(l.folded and '~' or mark, l.text, l.new_lnum)
  end
  return out
end

test('conflict: the two sides of a conflict and its markers', function()
  local lines, starts = conflict.classify({
    'a',
    '<<<<<<< HEAD',
    'ours',
    '=======',
    'theirs',
    '>>>>>>> other',
    'z',
  })
  eq({
    ' a|1',
    '!<<<<<<< HEAD|2',
    '<ours|3',
    '!=======|4',
    '>theirs|5',
    '!>>>>>>> other|6',
    ' z|7',
  }, dump(lines))
  eq({ 2 }, starts)
  -- what `gf` and the syntax are looked up by
  eq({ 'new', 2 }, { lines[3].side, lines[3].row })
end)

test('conflict: diff3 and zdiff3 add the base between the sides', function()
  local lines = conflict.classify({
    '<<<<<<< HEAD',
    'ours',
    '||||||| base',
    'base',
    '=======',
    'theirs',
    '>>>>>>> other',
  })
  eq({
    '!<<<<<<< HEAD|1',
    '<ours|2',
    '!||||||| base|3',
    '|base|4',
    '!=======|5',
    '>theirs|6',
    '!>>>>>>> other|7',
  }, dump(lines))
end)

test('conflict: every conflict in a file is found', function()
  local _, starts = conflict.classify({
    '<<<<<<< HEAD',
    'a',
    '=======',
    'b',
    '>>>>>>> other',
    '<<<<<<< HEAD',
    'c',
    '=======',
    'd',
    '>>>>>>> other',
  })
  eq({ 1, 6 }, starts)
end)

test('conflict: an empty side has only its markers', function()
  local lines = conflict.classify({ '<<<<<<< HEAD', '=======', 'theirs', '>>>>>>> other' })
  eq({ '!<<<<<<< HEAD|1', '!=======|2', '>theirs|3', '!>>>>>>> other|4' }, dump(lines))
end)

-- A marker that lost its partner, as when someone removed part of a conflict
-- by hand, would otherwise run the conflict on to the next one or to the end.
test('conflict: a conflict that is never closed is left as it is', function()
  local lines, starts = conflict.classify({
    '<<<<<<< HEAD',
    'kept by hand',
    '=======',
    'x',
    '<<<<<<< HEAD',
    'ours',
    '=======',
    'theirs',
    '>>>>>>> other',
    '<<<<<<< HEAD',
    'dangling',
  })
  eq({ 5 }, starts)
  local out = dump(lines)
  eq({ ' <<<<<<< HEAD|1', ' kept by hand|2', ' =======|3', ' x|4' }, vim.list_slice(out, 1, 4))
  eq({ ' <<<<<<< HEAD|10', ' dangling|11' }, vim.list_slice(out, 10, 11))
end)

test('conflict: a separator outside a conflict is ordinary text', function()
  local lines, starts = conflict.classify({ 'Title', '=======', '', '>>>>>>> not a marker' })
  eq({}, starts)
  eq({ ' Title|1', ' =======|2', ' |3', ' >>>>>>> not a marker|4' }, dump(lines))
end)

test('conflict: only seven characters make a marker', function()
  local _, starts = conflict.classify({ '<<<<<<<< HEAD', 'a', '=======', 'b', '>>>>>>> other' })
  eq({}, starts)
end)

test('conflict: a CRLF file still has its markers found', function()
  local _, starts =
    conflict.classify({ '<<<<<<< HEAD\r', 'a\r', '=======\r', 'b\r', '>>>>>>> other\r' })
  eq({ 1 }, starts)
end)

test('conflict: build gives nothing for a file with no conflict marked out', function()
  eq({ nil, {} }, { conflict.build({ 'a', 'b' }, 3) })
end)

test('conflict: build opens only the lines around each conflict', function()
  local work = { '1', '2', '3', '4', '5', '<<<<<<< HEAD', 'o', '=======', 't', '>>>>>>> x' }
  for i = 6, 10 do
    work[#work + 1] = tostring(i)
  end
  local lines, hunk_rows = conflict.build(work, 2)
  eq({
    '~1|1',
    '~2|2',
    '~3|3',
    ' 4|4',
    ' 5|5',
    '!<<<<<<< HEAD|6',
    '<o|7',
    '!=======|8',
    '>t|9',
    '!>>>>>>> x|10',
    ' 6|11',
    ' 7|12',
    '~8|13',
    '~9|14',
    '~10|15',
  }, dump(assert(lines)))
  eq({ 6 }, hunk_rows)
end)

-- `fold` makes one run of two conflicts with nothing between them, which would
-- leave `]c` with nowhere to stop at the second.
test('conflict: build marks each of two adjacent conflicts', function()
  local _, hunk_rows = conflict.build({
    '<<<<<<< HEAD',
    'a',
    '=======',
    'b',
    '>>>>>>> other',
    '<<<<<<< HEAD',
    'c',
    '=======',
    'd',
    '>>>>>>> other',
  }, 3)
  eq({ 1, 6 }, hunk_rows)
end)
