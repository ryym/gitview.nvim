local worddiff = require('gitview.diff.worddiff')


local M = {}

--- A line of the rendered buffer. `context`, `add` and `del` carry source text
--- and are the only kinds with a place in one of the versions, with `conflict`
--- for a line of an unmerged file that is part of a conflict; `file` and
--- `blank` are structural lines the view inserts, `subject`, `author`, `body`
--- and `stat` make up a commit's header, and `notice` stands where the diff
--- will be once it is read. None of those carry line numbers or a
--- `side`/`row`/`file` to look their syntax up by.
---
--- @class gitview.Line
--- @field text string source text without any gutter
--- @field kind 'context'|'add'|'del'|'conflict'|'file'|'blank'|'subject'|'author'|'body'|'stat'|'notice'|'skipped'
--- @field part 'marker'|'ours'|'base'|'theirs'? which part of a conflict a
---       `conflict` line is; see gitview.diff.conflict
--- @field byline string? a commit's author line only: who wrote it and how long
---       ago, said in brief for the header folded into that line
--- @field old_lnum integer? 1-based line number in the old version
--- @field new_lnum integer? 1-based line number in the new version
--- @field side 'old'|'new'|'index'? which version `text` came from; `index`
---       only in a mixed view
--- @field row integer? 0-based row of `text` in its version
--- @field file integer? index into `gitview.View.files`
--- @field folded true? a `context` line away from every change, which starts
---       out folded away. Each run of them is one fold.
--- @field stage 'staged'|'unstaged'|'index'? which layer a change belongs to, in
---       a mixed view only; see gitview.diff.mixed
--- @field index_pos integer? where the row sits in the index, in a mixed view
---       only: its own line number when the index has the row, and the line it
---       sits in front of otherwise. Staging a single line needs a patch stated
---       in the index's line numbers, which neither `old_lnum` nor `new_lnum`
---       gives. `side == 'index'` tells the two meanings apart.

--- Kinds that stand for a line of one of the versions, and so have a number in
--- the gutter.
--- @type table<string, true>
M.source_kinds = { context = true, add = true, del = true, conflict = true }

--- Whether a line takes the syntax of the version it comes from. A conflict's
--- markers are no code in any language, and would only be colored as errors.
--- @param l gitview.Line
--- @return boolean
function M.has_syntax(l)
  return M.source_kinds[l.kind] == true and l.part ~= 'marker'
end

--- `linematch` is off by default. It is a Neovim-only post-pass that re-pairs
--- lines inside a hunk and splits the hunk accordingly, which makes the result
--- disagree with `git diff` on the same input: `a b c d e` -> `a b X Y d e`
--- becomes "insert X" plus "c -> Y" instead of git's single "c -> X Y".
---
--- `ignore_whitespace` is `vim.diff`'s own, the equivalent of `git diff -w`. It
--- has four siblings there — `ignore_whitespace_change`,
--- `ignore_whitespace_change_at_eol`, `ignore_blank_lines` and
--- `ignore_cr_at_eol` — none of which is exposed yet.
---
--- @param old_lines string[]
--- @param new_lines string[]
--- @param opts? {algorithm?:string, linematch?:integer, ignore_whitespace?:boolean}
--- @return integer[][] hunks each is {old_start, old_count, new_start, new_count}
function M.hunks(old_lines, new_lines, opts)
  opts = opts or {}
  local function text(lines)
    return #lines == 0 and '' or (table.concat(lines, '\n') .. '\n')
  end
  return vim.diff(text(old_lines), text(new_lines), {
    result_type = 'indices',
    algorithm = opts.algorithm or 'histogram',
    linematch = opts.linematch or 0,
    ignore_whitespace = opts.ignore_whitespace or false,
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
--- @return gitview.Line[] lines
--- @return integer[] hunk_rows 1-based row of the first changed line of each hunk
function M.build(hunks, old_lines, new_lines, context)
  local out = {} --- @type gitview.Line[]
  local hunk_rows = {}
  local offset = 0 -- new_lnum - old_lnum for unchanged lines at this point

  --- @param from integer
  --- @param to integer
  --- @param folded true?
  local function push_context(from, to, folded)
    for i = from, to do
      out[#out + 1] = {
        text = old_lines[i],
        kind = 'context',
        old_lnum = i,
        new_lnum = i + offset,
        side = 'old',
        row = i - 1,
        folded = folded,
      }
    end
  end

  --- Emit an unchanged range, folding away all but `head` lines at its start and
  --- `tail` lines at its end. Emitting the whole range eagerly would double up
  --- lines that the next hunk is about to claim as changed.
  ---
  --- A closed fold still occupies a row, so folding a single line away saves no
  --- space and only makes the file harder to read. Such a range is left open.
  --- @param from integer
  --- @param to integer
  --- @param head integer
  --- @param tail integer
  local function push_unchanged(from, to, head, tail)
    local n = to - from + 1
    if n <= 0 then
      return
    end
    if n <= head + tail + 1 then
      push_context(from, to)
      return
    end
    push_context(from, from + head - 1)
    push_context(from + head, to - tail, true)
    push_context(to - tail + 1, to)
  end

  local prev_end = 0 -- last old line consumed
  for hi, h in ipairs(hunks) do
    local os_, oc, ns_, nc = h[1], h[2], h[3], h[4]
    local old_first = oc > 0 and os_ or os_ + 1
    local new_first = nc > 0 and ns_ or ns_ + 1

    push_unchanged(prev_end + 1, old_first - 1, hi == 1 and 0 or context, context)

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

  push_unchanged(prev_end + 1, #old_lines, context, 0)

  return out, hunk_rows
end

--- How many additions past the last paired one each deletion is compared
--- against. Every comparison is a word diff, so an unbounded search would cost
--- one per deletion and addition on a block rewritten wholesale.
local PAIR_LOOKAHEAD = 10

--- Blocks with more deleted or added lines than this are left unpaired. Word
--- highlights tell little in a replacement that large, and skipping it keeps the
--- cost of a wholesale rewrite from growing with its size.
local PAIR_MAX_BLOCK = 500

--- Pair up deleted and added lines that can be shown as line-to-line changes.
---
--- Within a del/add block, each deletion is paired with the first addition after
--- the last pair whose word diff is worth showing, as git-delta does. Pairing by
--- position instead would only work for equally sized blocks: a single line
--- inserted in the middle shifts every pair below it.
---
--- In a multi-file view one file's trailing deletions sit directly above the
--- next file's leading additions, so blocks are only paired when they belong to
--- the same file. In a mixed view they must also belong to the same stage: a
--- staged deletion followed by an unstaged addition is two separate changes.
---
--- @param lines gitview.Line[]
--- @return [integer, integer][] pairs of 1-based rows {del_row, add_row}
function M.change_pairs(lines)
  local pairs_ = {}
  local i = 1
  while i <= #lines do
    if lines[i].kind == 'del' then
      local file, stage = lines[i].file, lines[i].stage
      local function same(l, kind)
        return l and l.kind == kind and l.file == file and l.stage == stage
      end
      local del_start = i
      while same(lines[i], 'del') do
        i = i + 1
      end
      local del_end = i - 1
      local add_start = i
      while same(lines[i], 'add') do
        i = i + 1
      end
      local add_end = i - 1

      local too_large = del_end - del_start + 1 > PAIR_MAX_BLOCK
        or add_end - add_start + 1 > PAIR_MAX_BLOCK
      if not too_large then
        local next_add = add_start
        for d = del_start, del_end do
          if next_add > add_end then
            break
          end
          local old = lines[d].text
          for a = next_add, math.min(add_end, next_add + PAIR_LOOKAHEAD - 1) do
            local new = lines[a].text
            local old_ranges, new_ranges = worddiff.ranges(old, new)
            if worddiff.useful(old, new, old_ranges, new_ranges) then
              pairs_[#pairs_ + 1] = { d, a }
              next_add = a + 1
              break
            end
          end
        end
      end
    else
      i = i + 1
    end
  end
  return pairs_
end

return M
