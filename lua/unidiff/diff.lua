local M = {}

--- @class unidiff.Line
--- @field text string source text without any gutter
--- @field kind 'context'|'add'|'del'
--- @field old_lnum integer? 1-based line number in the old version
--- @field new_lnum integer? 1-based line number in the new version
--- @field side 'old'|'new' which version `text` came from
--- @field row integer 0-based row of `text` in its version

--- @param old_lines string[]
--- @param new_lines string[]
--- @param opts? {algorithm?:string, linematch?:integer}
--- @return integer[][] hunks each is {old_start, old_count, new_start, new_count}
function M.hunks(old_lines, new_lines, opts)
  opts = opts or {}
  local function text(lines)
    return #lines == 0 and '' or (table.concat(lines, '\n') .. '\n')
  end
  return vim.diff(text(old_lines), text(new_lines), {
    result_type = 'indices',
    algorithm = opts.algorithm or 'histogram',
    linematch = opts.linematch or 60,
  })
end

--- Build the unified line list from raw hunks.
---
--- `vim.diff` reports a zero-count side with `start` pointing at the line *before*
--- which the change applies, so there the first affected line is `start + 1`.
--- Ignoring that shifts every context calculation by one.
---
--- @param hunks integer[][]
--- @param old_lines string[]
--- @param new_lines string[]
--- @param context integer number of unchanged lines kept around each hunk
--- @return unidiff.Line[] lines
--- @return integer[] hunk_rows 1-based row of the first changed line of each hunk
--- @return {row:integer, count:integer}[] gaps skipped ranges, `row` is the
---         1-based row the separator belongs above (may be #lines + 1)
function M.build(hunks, old_lines, new_lines, context)
  local out = {} --- @type unidiff.Line[]
  local hunk_rows, gaps = {}, {}
  local offset = 0 -- new_lnum - old_lnum for unchanged lines at this point

  --- @param from integer
  --- @param to integer
  local function push_context(from, to)
    for i = from, to do
      out[#out + 1] = {
        text = old_lines[i],
        kind = 'context',
        old_lnum = i,
        new_lnum = i + offset,
        side = 'old',
        row = i - 1,
      }
    end
  end

  --- Emit an unchanged range, keeping only `head` lines at its start and `tail`
  --- lines at its end. Emitting the whole range eagerly would double up lines
  --- that the next hunk is about to claim as changed.
  --- @param from integer
  --- @param to integer
  --- @param head integer
  --- @param tail integer
  local function push_gap(from, to, head, tail)
    local n = to - from + 1
    if n <= 0 then
      return
    end
    if n <= head + tail then
      push_context(from, to)
      return
    end
    push_context(from, from + head - 1)
    gaps[#gaps + 1] = { row = #out + 1, count = n - head - tail }
    push_context(to - tail + 1, to)
  end

  local prev_end = 0 -- last old line consumed
  for hi, h in ipairs(hunks) do
    local os_, oc, ns_, nc = h[1], h[2], h[3], h[4]
    local old_first = oc > 0 and os_ or os_ + 1
    local new_first = nc > 0 and ns_ or ns_ + 1

    push_gap(prev_end + 1, old_first - 1, hi == 1 and 0 or context, context)

    hunk_rows[#hunk_rows + 1] = #out + 1
    for i = old_first, old_first + oc - 1 do
      out[#out + 1] =
        { text = old_lines[i], kind = 'del', old_lnum = i, side = 'old', row = i - 1 }
    end
    for i = new_first, new_first + nc - 1 do
      out[#out + 1] =
        { text = new_lines[i], kind = 'add', new_lnum = i, side = 'new', row = i - 1 }
    end

    prev_end = old_first + oc - 1
    offset = offset + (nc - oc)
  end

  push_gap(prev_end + 1, #old_lines, context, 0)

  return out, hunk_rows, gaps
end

--- Pair up del/add blocks that can be shown as line-to-line changes.
--- @param lines unidiff.Line[]
--- @return [integer, integer][] pairs of 1-based rows {del_row, add_row}
function M.change_pairs(lines)
  local pairs_ = {}
  local i = 1
  while i <= #lines do
    if lines[i].kind == 'del' then
      local del_start = i
      while lines[i] and lines[i].kind == 'del' do
        i = i + 1
      end
      local del_end = i - 1
      local add_start = i
      while lines[i] and lines[i].kind == 'add' do
        i = i + 1
      end
      local add_end = i - 1
      if add_end >= add_start and (del_end - del_start) == (add_end - add_start) then
        for k = 0, del_end - del_start do
          pairs_[#pairs_ + 1] = { del_start + k, add_start + k }
        end
      end
    else
      i = i + 1
    end
  end
  return pairs_
end

return M
