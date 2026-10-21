local color = require('gitview.diff.color')

local test, eq = _G.test, _G.eq

local WHITE, BLACK = 0xffffff, 0x000000

--- @param rgb integer
--- @return integer[]
local function channels(rgb)
  return {
    bit.band(bit.rshift(rgb, 16), 0xff),
    bit.band(bit.rshift(rgb, 8), 0xff),
    bit.band(rgb, 0xff),
  }
end

test('a word color that already stands out is the plain push', function()
  -- Neovim's own dark DiffAdd on its own background.
  local base, tint = 0x14161b, 0x005523
  eq(color.scale(tint, base, 1.4), color.word(tint, base, 1, 1.4, WHITE))
end)

test('a faint tint is pushed further along its own hue', function()
  -- A diff color close to the background, as some colorschemes have: the plain
  -- push gets the word only a few steps away from its line.
  local base, tint = 0x1a1b26, 0x20303b
  assert(color.distance(color.scale(tint, base, 1.4), tint) < color.MIN_DISTANCE)

  local word = color.word(tint, base, 1, 1.4, WHITE)
  assert(color.distance(word, tint) >= color.MIN_DISTANCE, 'word must stand out')
  local b, t, w = channels(base), channels(tint), channels(word)
  for i = 1, 3 do
    assert(
      (w[i] - t[i]) * (t[i] - b[i]) >= 0,
      ('channel %d must move away from the background, as the tint does'):format(i)
    )
  end
  -- Just far enough: the search stops at the bound rather than overshooting.
  assert(color.distance(word, tint) < color.MIN_DISTANCE + 0.01)
end)

test('a staged word stands out from the staged line', function()
  local base, tint = 0x1a1b26, 0x20303b
  local line = color.scale(tint, base, 0.6)
  assert(color.distance(color.word(tint, base, 0.6, 0.9, WHITE), line) >= color.MIN_DISTANCE)
end)

test('a tint with nowhere left to go turns back towards the background', function()
  local base, tint = BLACK, 0x00ff00
  local word = color.word(tint, base, 1, 1.4, WHITE)
  assert(color.distance(word, tint) >= color.MIN_DISTANCE, 'word must stand out')
  assert(channels(word)[2] < 0xff, 'word must be darker than its line')
end)

test('a line with no tint of its own turns towards the pole', function()
  local base = 0x202020
  local word = color.word(base, base, 1, 1.4, WHITE)
  assert(color.distance(word, base) >= color.MIN_DISTANCE, 'word must stand out')
  local w = channels(word)
  assert(w[1] > 0x20 and w[1] == w[2] and w[2] == w[3], 'word must be a lighter gray')

  word = color.word(WHITE, WHITE, 1, 1.4, BLACK)
  assert(color.distance(word, WHITE) >= color.MIN_DISTANCE, 'word must stand out on light')
end)
