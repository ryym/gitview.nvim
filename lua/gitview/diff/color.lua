local M = {}

--- How far apart a changed word's color and its line's must be, in OKLab
--- distance, for the word to be told apart at a glance. Colorschemes where the
--- words could hardly be seen measured 0.02 to 0.03 at the plain 1.4 push, and
--- 0.05 still looked faint in use; 0.07 is where they started to stand out.
M.MIN_DISTANCE = 0.07

--- Move a color away from (`factor` > 1) or towards (`factor` < 1) `base`,
--- channel by channel. Channels stop at 0 and 255.
--- @param rgb integer
--- @param base integer
--- @param factor number
--- @return integer
function M.scale(rgb, base, factor)
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local b = bit.band(bit.rshift(base, shift), 0xff)
    local c = bit.band(bit.rshift(rgb, shift), 0xff)
    local v = math.max(0, math.min(255, math.floor(b + (c - b) * factor)))
    out = out + bit.lshift(v, shift)
  end
  return out
end

--- @param c integer 0-255 sRGB channel
--- @return number
local function linear(c)
  c = c / 255
  return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

--- @param rgb integer
--- @return number L
--- @return number a
--- @return number b
local function oklab(rgb)
  local r = linear(bit.band(bit.rshift(rgb, 16), 0xff))
  local g = linear(bit.band(bit.rshift(rgb, 8), 0xff))
  local b = linear(bit.band(rgb, 0xff))
  local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
  local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
  local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
  return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end

--- How different two colors look. RGB distance would not do: a step in green
--- shows far more than the same step in blue.
--- @param x integer
--- @param y integer
--- @return number
function M.distance(x, y)
  local l1, a1, b1 = oklab(x)
  local l2, a2, b2 = oklab(y)
  return math.sqrt((l1 - l2) ^ 2 + (a1 - a2) ^ 2 + (b1 - b2) ^ 2)
end

--- The first color along `path` that stands `MIN_DISTANCE` away from `from`.
--- @param path fun(u: number): integer from u = 0 to 1
--- @param from integer
--- @return integer?
local function reach(path, from)
  if M.distance(path(1), from) < M.MIN_DISTANCE then
    return nil
  end
  local lo, hi = 0, 1
  for _ = 1, 24 do
    local mid = (lo + hi) / 2
    if M.distance(path(mid), from) < M.MIN_DISTANCE then
      lo = mid
    else
      hi = mid
    end
  end
  return path(hi)
end

--- The color of a changed word on a line of `tint`, scaled from `base` by
--- `line`.
---
--- It is `tint` scaled by `word`, as long as that stands out from the line
--- enough. When it does not, as with a colorscheme whose diff colors sit close
--- to its background, the word goes further in the same direction until it
--- does, so it stays of the line's hue. Failing that, because the channels have
--- nowhere left to go or `tint` has no hue to follow, it turns back towards
--- `base`, then towards `pole`.
--- @param tint integer
--- @param base integer the editor background
--- @param line number
--- @param word number
--- @param pole integer white on a dark background, black on a light one
--- @return integer
function M.word(tint, base, line, word, pole)
  local line_color = M.scale(tint, base, line)
  local plain = M.scale(tint, base, word)
  if M.distance(plain, line_color) >= M.MIN_DISTANCE then
    return plain
  end
  -- Any factor this large has every channel that moves at all at its limit.
  local far = 256
  return reach(function(u)
    return M.scale(tint, base, word + (far - word) * u)
  end, line_color) or reach(function(u)
    return M.scale(tint, base, line * (1 - u))
  end, line_color) or reach(function(u)
    return M.scale(pole, line_color, u)
  end, line_color) or plain
end

return M
