--- Experimental: one unified diff of HEAD -> working tree in which every changed
--- line also says whether that change is staged.
---
--- The three versions are aligned on the index. HEAD -> index gives the staged
--- changes and index -> working tree the unstaged ones, and every index line is
--- placed by both diffs at once. A line present in some of the versions and not
--- the others falls into exactly one of these:
---
--- | HEAD | index | work | row                                        |
--- | ---- | ----- | ---- | ------------------------------------------ |
--- | yes  | yes   | yes  | context                                    |
--- | yes  | -     | -    | `del`, staged                              |
--- | -    | yes   | yes  | `add`, staged                              |
--- | yes  | yes   | -    | `del`, unstaged                            |
--- | -    | -     | yes  | `add`, unstaged                            |
--- | -    | yes   | -    | `del`, `index`: staged, then removed again |
---
--- A line in HEAD and the working tree but not in the index cannot appear as
--- one row: the index has nowhere to put it, so it shows up as a staged
--- deletion and an unstaged addition of the same text.
local dlib = require('unidiff.diff.lines')

local M = {}

--- @class unidiff.Alignment
--- @field old_to_new table<integer, integer> unchanged lines, old lnum -> new lnum
--- @field new_to_old table<integer, integer> unchanged lines, new lnum -> old lnum
--- @field old_only table<integer, integer[]> deleted old lnums, keyed by the new
---        lnum they sit in front of
--- @field new_only table<integer, integer[]> added new lnums, keyed by the old
---        lnum they sit in front of

--- The line correspondence a list of hunks implies. Positions are "in front of
--- line N", with N one past the end for anything at the very end.
--- @param hunks integer[][]
--- @param n_old integer
--- @return unidiff.Alignment
function M.align(hunks, n_old)
  local a = { old_to_new = {}, new_to_old = {}, old_only = {}, new_only = {} }
  local o, n = 1, 1
  local function keep_until(stop)
    while o < stop do
      a.old_to_new[o], a.new_to_old[n] = n, o
      o, n = o + 1, n + 1
    end
  end
  local function push(tbl, key, lnum)
    tbl[key] = tbl[key] or {}
    table.insert(tbl[key], lnum)
  end

  for _, h in ipairs(hunks) do
    local os_, oc, ns_, nc = h[1], h[2], h[3], h[4]
    -- a zero-count side points at the line before the change; see diff.lines.build
    local old_first = oc > 0 and os_ or os_ + 1
    local new_first = nc > 0 and ns_ or ns_ + 1
    keep_until(old_first)
    for k = 0, oc - 1 do
      push(a.old_only, new_first, old_first + k)
    end
    for k = 0, nc - 1 do
      push(a.new_only, old_first + oc, new_first + k)
    end
    o, n = old_first + oc, new_first + nc
  end
  keep_until(n_old + 1)
  return a
end

--- Every line of all three versions, in display order. `old_lnum` is the line
--- number in HEAD and `new_lnum` the one in the working tree; a line in neither
--- has no number at all. `index_pos` places every row against the index, which
--- is what staging a single line has to be stated in terms of.
--- @param head string[]
--- @param index string[]
--- @param work string[]
--- @param opts? {algorithm?:string, linematch?:integer}
--- @return unidiff.Line[]
function M.merge(head, index, work, opts)
  local staged = M.align(dlib.hunks(head, index, opts), #head)
  local unstaged = M.align(dlib.hunks(index, work, opts), #index)
  local out = {}

  local function push_head_deletions(p)
    for _, lnum in ipairs(staged.old_only[p] or {}) do
      out[#out + 1] = {
        text = head[lnum],
        kind = 'del',
        stage = 'staged',
        old_lnum = lnum,
        index_pos = p,
        side = 'old',
        row = lnum - 1,
      }
    end
  end
  local function push_work_additions(p)
    for _, lnum in ipairs(unstaged.new_only[p] or {}) do
      out[#out + 1] = {
        text = work[lnum],
        kind = 'add',
        stage = 'unstaged',
        new_lnum = lnum,
        index_pos = p,
        side = 'new',
        row = lnum - 1,
      }
    end
  end

  for p = 1, #index + 1 do
    -- Both groups sit between index lines p-1 and p. Additions that replace an
    -- index line the working tree dropped belong to that line, so they go
    -- first; otherwise the usual deletions-then-additions order reads better.
    -- Getting this wrong splits a partially staged hunk into an interleaving
    -- of the two layers.
    if p > 1 and not unstaged.old_to_new[p - 1] then
      push_work_additions(p)
      push_head_deletions(p)
    else
      push_head_deletions(p)
      push_work_additions(p)
    end

    if p <= #index then
      local h, w = staged.new_to_old[p], unstaged.old_to_new[p]
      local l = {
        text = index[p],
        old_lnum = h,
        new_lnum = w,
        index_pos = p,
        side = 'index',
        row = p - 1,
      }
      if h and w then
        l.kind = 'context'
      elseif h then
        l.kind, l.stage = 'del', 'unstaged'
      elseif w then
        l.kind, l.stage = 'add', 'staged'
      else
        l.kind, l.stage = 'del', 'index'
      end
      out[#out + 1] = l
    end
  end
  return out
end

--- Collapse unchanged runs the way diff.lines.build does: `context` lines are
--- kept on each side of a change, nothing before the first or after the last,
--- and a run only one line longer than what is kept is shown whole.
--- @param lines unidiff.Line[]
--- @param context integer
--- @return unidiff.Line[] lines
--- @return integer[] hunk_rows
function M.trim(lines, context)
  local out, hunk_rows = {}, {}
  local n = #lines
  local i = 1
  while i <= n do
    if lines[i].kind == 'context' then
      local j = i
      while j < n and lines[j + 1].kind == 'context' do
        j = j + 1
      end
      local head = i == 1 and 0 or context
      local tail = j == n and 0 or context
      if j - i + 1 <= head + tail + 1 then
        vim.list_extend(out, lines, i, j)
      else
        vim.list_extend(out, lines, i, i + head - 1)
        out[#out + 1] = { text = dlib.gap_label(j - i + 1 - head - tail), kind = 'gap' }
        vim.list_extend(out, lines, j - tail + 1, j)
      end
      i = j + 1
    else
      if i == 1 or lines[i - 1].kind == 'context' then
        hunk_rows[#hunk_rows + 1] = #out + 1
      end
      out[#out + 1] = lines[i]
      i = i + 1
    end
  end
  return out, hunk_rows
end

--- @param head string[]
--- @param index string[]
--- @param work string[]
--- @param context integer
--- @param opts? {algorithm?:string, linematch?:integer}
--- @return unidiff.Line[]? lines nil when none of the three versions differ
--- @return integer[] hunk_rows
function M.build(head, index, work, context, opts)
  local lines = M.merge(head, index, work, opts)
  for _, l in ipairs(lines) do
    if l.kind ~= 'context' then
      return M.trim(lines, context)
    end
  end
  return nil, {}
end

return M
