local worddiff = require('unidiff.worddiff')

local test, eq = _G.test, _G.eq

--- @param s string
--- @param ranges {start_col:integer, end_col:integer}[]
--- @return string[]
local function slice(s, ranges)
  local out = {}
  for i, r in ipairs(ranges) do
    out[i] = s:sub(r.start_col + 1, r.end_col)
  end
  return out
end

test('ascii insertion', function()
  local o, n = worddiff.ranges('world', 'brave world')
  eq({}, slice('world', o))
  eq({ 'brave ' }, slice('brave world', n))
end)

test('ascii replacement', function()
  local o, n = worddiff.ranges('return a + b', 'return a - b')
  eq({ '+' }, slice('return a + b', o))
  eq({ '-' }, slice('return a - b', n))
end)

test('multibyte text yields byte offsets on character boundaries', function()
  -- The design note used Lua 5.3's `utf8` library, which LuaJIT does not have;
  -- getting this wrong silently produces ranges that cut characters in half.
  local old = 'こんにちは world'
  local new = 'こんばんは world'
  local o, n = worddiff.ranges(old, new)
  eq({ 'にち' }, slice(old, o))
  eq({ 'ばん' }, slice(new, n))
  for _, r in ipairs(n) do
    eq(new:sub(r.start_col + 1, r.end_col), vim.fn.strcharpart(
      new,
      vim.fn.strchars(new:sub(1, r.start_col)),
      vim.fn.strchars(new:sub(r.start_col + 1, r.end_col))
    ), 'range must not split a character')
  end
end)

test('ranges stay inside the string', function()
  local old, new = 'call(abc)', 'call(abcdef)'
  local o, n = worddiff.ranges(old, new)
  for _, r in ipairs(o) do
    assert(r.end_col <= #old, 'old range out of bounds')
  end
  for _, r in ipairs(n) do
    assert(r.end_col <= #new, 'new range out of bounds')
  end
  -- a renamed identifier is highlighted whole, the way GitHub does it
  eq({ 'abc' }, slice(old, o))
  eq({ 'abcdef' }, slice(new, n))
end)

test('empty line pairs produce nothing', function()
  local o, n = worddiff.ranges('', 'abc')
  eq({}, o)
  eq({}, n)
end)

test('useful() rejects near-total rewrites', function()
  local old, new = 'completely different text', 'nothing alike whatsoever!'
  local o, n = worddiff.ranges(old, new)
  eq(false, worddiff.useful(old, new, o, n))
end)

test('useful() accepts small edits', function()
  local old, new = 'local x = compute(a, b)', 'local x = compute(a, b, c)'
  local o, n = worddiff.ranges(old, new)
  eq(true, worddiff.useful(old, new, o, n))
end)
