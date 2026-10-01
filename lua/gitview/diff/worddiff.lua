local M = {}

--- Split a line into diff tokens: runs of word characters, runs of whitespace,
--- and every other character on its own.
---
--- Diffing single characters (as a first cut of this did) scatters highlights
--- across a line whenever two unrelated lines happen to share letters, so the
--- result is noise rather than a readable "what changed here".
---
--- LuaJIT has no `utf8` library, so `vim.fn.split(s, '\\zs')` is what splits on
--- character boundaries; multibyte characters each become their own token.
---
--- @param s string
--- @return string[] tokens
--- @return integer[] offsets 0-based byte offset of each token, plus #s at the end
local function tokenize(s)
  local tokens, offsets = {}, {}
  local off = 0
  local class = function(c)
    if #c > 1 then
      return 'other'
    elseif c:match('[%w_]') then
      return 'word'
    elseif c:match('%s') then
      return 'space'
    end
    return 'other'
  end

  local cur, cur_class, cur_off = nil, nil, 0
  for _, c in ipairs(vim.fn.split(s, '\\zs')) do
    local cl = class(c)
    if cur and cl == cur_class and cl ~= 'other' then
      cur = cur .. c
    else
      if cur then
        tokens[#tokens + 1], offsets[#offsets + 1] = cur, cur_off
      end
      cur, cur_class, cur_off = c, cl, off
    end
    off = off + #c
  end
  if cur then
    tokens[#tokens + 1], offsets[#offsets + 1] = cur, cur_off
  end
  offsets[#tokens + 1] = off
  return tokens, offsets
end

--- Merge ranges that touch, so a changed word plus its trailing space renders as
--- one block instead of two.
--- @param ranges {start_col:integer, end_col:integer}[]
local function merge(ranges)
  local out = {}
  for _, r in ipairs(ranges) do
    local last = out[#out]
    if last and last.end_col == r.start_col then
      last.end_col = r.end_col
    else
      out[#out + 1] = r
    end
  end
  return out
end

--- Word-level diff between two lines, returned as byte ranges.
--- @param old string
--- @param new string
--- @return {start_col:integer, end_col:integer}[] old_ranges
--- @return {start_col:integer, end_col:integer}[] new_ranges
function M.ranges(old, new)
  local ot, ooff = tokenize(old)
  local nt, noff = tokenize(new)
  if #ot == 0 or #nt == 0 then
    return {}, {}
  end

  local hunks = vim.diff(
    table.concat(ot, '\n') .. '\n',
    table.concat(nt, '\n') .. '\n',
    { result_type = 'indices', algorithm = 'minimal' }
  )

  local old_ranges, new_ranges = {}, {}
  for _, h in ipairs(hunks) do
    local os_, oc, ns_, nc = h[1], h[2], h[3], h[4]
    if oc > 0 then
      old_ranges[#old_ranges + 1] = { start_col = ooff[os_], end_col = ooff[os_ + oc] }
    end
    if nc > 0 then
      new_ranges[#new_ranges + 1] = { start_col = noff[ns_], end_col = noff[ns_ + nc] }
    end
  end
  return merge(old_ranges), merge(new_ranges)
end

--- Skip word-diff for pairs that share almost nothing; highlighting nearly the
--- whole line adds noise rather than information.
--- @param old string
--- @param new string
--- @param old_ranges {start_col:integer, end_col:integer}[]
--- @param new_ranges {start_col:integer, end_col:integer}[]
--- @return boolean
function M.useful(old, new, old_ranges, new_ranges)
  local function covered(rs)
    local n = 0
    for _, r in ipairs(rs) do
      n = n + (r.end_col - r.start_col)
    end
    return n
  end
  local total = #old + #new
  if total == 0 or (#old_ranges == 0 and #new_ranges == 0) then
    return false
  end
  return (covered(old_ranges) + covered(new_ranges)) / total < 0.7
end

return M
