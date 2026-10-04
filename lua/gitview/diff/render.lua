local hl = require('gitview.diff.highlight')
local util = require('gitview.util')
local worddiff = require('gitview.diff.worddiff')
local dlib = require('gitview.diff.lines')
local perf = require('gitview.perf')
local vlib = require('gitview.diff.view')

local M = {}

local ns_syntax = vim.api.nvim_create_namespace('gitview.syntax')
local ns_diff = vim.api.nvim_create_namespace('gitview.diff')

--- Kept off `M` on purpose. The window options call into this module as
--- `v:lua.require(...).fn()`, which converts `M` into a Vim value on every call:
--- a view reachable from it would be copied once per line on each redraw, and
--- once per line per line whenever 'foldexpr' reevaluates the whole buffer.
--- @type table<integer, gitview.View>
local views = {}

--- The view `buf` is showing, if it is showing one.
--- @param buf integer
--- @return gitview.View?
function M.view_of(buf)
  return views[buf]
end

--- @class gitview.File
--- @field path string absolute path in the working tree
--- @field label string what the header shows
--- @field old_buf integer ghost buffer holding the old version
--- @field new_buf integer ghost buffer holding the new version
--- @field index_buf integer? ghost buffer holding the index version, mixed views only
--- @field lang string language for highlight collection
--- @field row integer 1-based row of this file's header line

--- @class gitview.View
--- @field lines gitview.Line[]
--- @field files gitview.File[]
--- @field hunk_rows integer[] rows worth jumping between, ascending
--- @field file_rows integer[] the rows of `files`' header lines, ascending
--- @field rev string
--- @field note string? extra text for the winbar, e.g. skipped files
--- @field mixed boolean? staged and unstaged changes in one view; see gitview.diff.mixed
--- @field header_rows integer? how many rows at the top introduce the view rather
---        than belong to a file: a commit's message and stat. All but the
---        subject fold as one, as does each run of `folded` lines.

--- Highlight groups are defined on first use rather than from `setup()`, so a
--- diff opened without any configuration still gets its colors. Doing it lazily
--- also means the colorscheme is loaded by the time `DiffAdd` is read.
local highlights = util.highlights('gitview.highlights', function(set)
  --- Diff groups are taken background-only. Colorschemes give DiffAdd/DiffDelete
  --- a foreground as well, and a line highlight that carries one would repaint
  --- every character, erasing the syntax colors we just replayed.
  --- @param name string
  --- @param fallback string
  local function bg_only(name, fallback)
    local h = vim.api.nvim_get_hl(0, { name = name, link = false })
    return { bg = h.bg or tonumber(fallback:sub(2), 16), ctermbg = h.ctermbg }
  end

  --- Move a color away from (`factor` > 1) or towards (`factor` < 1) the
  --- normal background.
  ---
  --- `Normal` carries no background of its own when the colorscheme lets the
  --- terminal's background show through, and that color cannot be read back, so
  --- 'background' picks which end of the range to push away from. Falling back
  --- to `spec` instead made the word highlight identical to the line highlight,
  --- which is to say invisible.
  --- @param spec table result of bg_only
  --- @param factor number
  local function scale(spec, factor)
    if not spec.bg then
      return spec
    end
    local base = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg
      or (vim.o.background == 'light' and 0xffffff or 0x000000)
    local out = 0
    for _, shift in ipairs({ 16, 8, 0 }) do
      local b = bit.band(bit.rshift(base, shift), 0xff)
      local c = bit.band(bit.rshift(spec.bg, shift), 0xff)
      local v = math.max(0, math.min(255, math.floor(b + (c - b) * factor)))
      out = out + bit.lshift(v, shift)
    end
    -- `ctermbg` is a palette index, so it cannot be scaled the same way. Reusing
    -- the line color at least keeps a background in 256-color terminals, where
    -- dropping it left the word ranges with no highlight at all.
    return { bg = out, ctermbg = spec.ctermbg }
  end

  -- Word-level highlights must stay recognisably "the add color" / "the delete
  -- color", so they are the same hue pushed further away from the background
  -- rather than a third, unrelated color.
  local add = bg_only('DiffAdd', '#20301e')
  local del = bg_only('DiffDelete', '#3a1f1c')
  set('GitViewAdd', add)
  set('GitViewDelete', del)
  set('GitViewAddText', scale(add, 1.4))
  set('GitViewDeleteText', scale(del, 1.4))
  -- Staged changes in a mixed view are the same hues, faded: they are settled,
  -- and what is still unstaged is what needs attention. The gutter marks them
  -- too, since 256-color terminals get no fading.
  set('GitViewStagedAdd', scale(add, 0.5))
  set('GitViewStagedDelete', scale(del, 0.5))
  set('GitViewStagedAddText', scale(add, 0.9))
  set('GitViewStagedDeleteText', scale(del, 0.9))
  set('GitViewStagedSign', { link = 'Special' })
  set('GitViewOldLnum', { link = 'LineNr' })
  set('GitViewNewLnum', { link = 'LineNr' })
  set('GitViewSeparator', { link = 'Folded' })
  set('GitViewFileHeader', { link = 'Title' })
  -- Also defined by `ui.list`, alike, so a sha has one color in both panes
  -- whichever module is drawn first.
  set('GitViewCommitSha', { link = 'Identifier' })
  set('GitViewFileRule', { link = 'WinSeparator' })
  set('GitViewCommitSubject', { link = 'Title' })
  set('GitViewCommitAuthor', { link = 'Comment' })
  set('GitViewStatAdd', { link = 'Added' })
  set('GitViewStatDelete', { link = 'Removed' })
end)

M.setup_highlights = highlights.apply
M.ensure_highlights = highlights.ensure
--- Testing hook: forget that the groups were ever defined.
M.ensure_highlights_reset = highlights.forget

local SIGN = { add = '+', del = '-', context = ' ' }
local LINE_HL = {
  add = 'GitViewAdd',
  del = 'GitViewDelete',
  file = 'GitViewFileHeader',
  subject = 'GitViewCommitSubject',
  author = 'GitViewCommitAuthor',
  -- as `notice` paints the line it replaces a whole buffer with
  notice = 'GitViewSeparator',
}
local TEXT_HL = { add = 'GitViewAddText', del = 'GitViewDeleteText' }
local STAT_HL = { ['%++'] = 'GitViewStatAdd', ['%-+'] = 'GitViewStatDelete' }
local STAGED_LINE_HL = { add = 'GitViewStagedAdd', del = 'GitViewStagedDelete' }
local STAGED_TEXT_HL = { add = 'GitViewStagedAddText', del = 'GitViewStagedDeleteText' }

--- @param l gitview.Line
--- @return string?
local function line_hl_of(l)
  return l.stage == 'staged' and STAGED_LINE_HL[l.kind] or LINE_HL[l.kind]
end

--- @param l gitview.Line
--- @return string
local function text_hl_of(l)
  return l.stage == 'staged' and STAGED_TEXT_HL[l.kind] or TEXT_HL[l.kind]
end

--- The rule a file's header is drawn on, so that where one file ends and the
--- next begins can be seen at a glance. It runs through the gutter up to the
--- name, and on from the name's end, where it is cut at the window's right
--- edge: it only has to be longer than any window is wide.
local RULE = ('─'):rep(512)

--- How many lines each file adds and deletes, from HEAD to the working tree in
--- a mixed view: a row only the index has is in neither.
--- @param view gitview.View
--- @return {add:integer, del:integer}[] by file
local function file_stats(view)
  local stats = {}
  for i = 1, #view.files do
    stats[i] = { add = 0, del = 0 }
  end
  for _, l in ipairs(view.lines) do
    local s = l.file and stats[l.file]
    if s and (l.kind == 'add' or l.kind == 'del') and l.stage ~= 'index' then
      s[l.kind] = s[l.kind] + 1
    end
  end
  return stats
end

--- A buffer to draw diffs in. It is made once and drawn into repeatedly: a view
--- that showed one file can be replaced by one showing another without swapping
--- the buffer out of its window, which would fire the Buf* autocommands on every
--- keystroke of a file list.
--- @return integer bufnr
function M.create_buffer()
  return util.scratch_buffer('gitview-diff', views)
end

--- The row a commit's header folds from. The subject above it stays out of the
--- fold, so that however long it is, it never pushes what the folded header
--- says off the screen.
local HEADER_FOLD_ROW = 2

--- What names a fold across views: `header` for a commit's header, and the
--- file and the new line number of its first row for a run of unchanged lines.
--- Staging leaves the working tree alone, and a commit never changes, so a run
--- keeps its name for as long as the same thing is being redrawn.
--- @param view gitview.View
--- @param row integer 1-based first row of the fold
--- @return string
local function fold_key(view, row)
  if view.header_rows and row == HEADER_FOLD_ROW then
    return 'header'
  end
  local l = view.lines[row]
  return ('%s:%d'):format(view.files[l.file].path, l.new_lnum)
end

--- The first row of every fold `view` makes.
--- @param view gitview.View
--- @return integer[]
local function fold_starts(view)
  local starts = view.header_rows and { HEADER_FOLD_ROW } or {}
  for row, l in ipairs(view.lines) do
    local prev = view.lines[row - 1]
    if l.folded and not (prev and prev.folded) then
      starts[#starts + 1] = row
    end
  end
  return starts
end

--- Which folds are open, by `fold_key`, in each window showing `buf`.
---
--- Replacing the lines under a fold opens or closes it depending on how its
--- extent changed, so a fold opened on one view would be found open or closed
--- on the next more or less at random. What the reader chose is carried over
--- instead, and 'foldlevel' only decides for a fold that has no counterpart.
--- @param buf integer
--- @return table<integer, table<string, boolean>> by window
local function fold_states(buf)
  local old = views[buf]
  local states = {}
  if old then
    local starts = fold_starts(old)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      states[win] = vim.api.nvim_win_call(win, function()
        local open = {}
        for _, row in ipairs(starts) do
          open[fold_key(old, row)] = vim.fn.foldclosed(row) == -1
        end
        return open
      end)
    end
  end
  return states
end

--- @param view gitview.View
--- @param states table<integer, table<string, boolean>> from `fold_states`
local function restore_folds(view, states)
  local starts = fold_starts(view)
  for win, open in pairs(states) do
    -- A window the buffer was moved into keeps its own folding, and has no fold
    -- here to open or close.
    pcall(vim.api.nvim_win_call, win, function()
      local default = vim.wo.foldlevel > 0
      for _, row in ipairs(starts) do
        local want = open[fold_key(view, row)]
        if want == nil then
          want = default
        end
        if want ~= (vim.fn.foldclosed(row) == -1) then
          vim.cmd(('%dfold%s'):format(row, want and 'open' or 'close'))
        end
      end
    end)
  end
end

--- A view with more open rows than this is shown before their syntax is
--- collected, and the syntax is filled in afterwards. Collecting is most of the
--- cost of a large view, but colors appearing a moment late would only flicker
--- on the small views that are redrawn all the time, such as a file being
--- staged hunk by hunk.
local PROGRESSIVE_ROWS = 1000

--- How long one step of filling in the syntax may run before it yields to the
--- editor. A file is never split, so a step overruns by up to one file.
local STEP_BUDGET_MS = 10

--- The rows of one file whose syntax is collected together, and the rows of
--- each version they show.
--- @class gitview.FillJob
--- @field file integer index into `gitview.View.files`
--- @field rows integer[] 1-based rows of the view
--- @field want table<string, table<integer, true>> rows of each version

--- The rows each file occupies, split into those drawn open and those folded
--- away.
---
--- Only a fraction of each version is open to begin with. The legacy syntax path
--- probes byte by byte, so telling it which rows matter keeps what the reader
--- waits for bounded by the size of the diff rather than the size of the file.
--- @param view gitview.View
--- @return gitview.FillJob[] open by file
--- @return gitview.FillJob[] folded by file
local function rows_by_file(view)
  local open, folded = {}, {}
  for i = 1, #view.files do
    open[i] = { file = i, rows = {}, want = { old = {}, new = {}, index = {} } }
    folded[i] = { file = i, rows = {}, want = { old = {}, new = {}, index = {} } }
  end
  for row, l in ipairs(view.lines) do
    if dlib.source_kinds[l.kind] then
      local job = (l.folded and folded or open)[l.file]
      table.insert(job.rows, row)
      job.want[l.side][l.row] = true
    end
  end
  return open, folded
end

--- Collect one file's syntax from its ghost buffers and replay it onto `buf`.
--- @param buf integer
--- @param view gitview.View
--- @param job gitview.FillJob from `rows_by_file`
local function fill_file(buf, view, job)
  local f = view.files[job.file]
  local want = job.want
  local segs = {
    old = hl.collect(f.old_buf, f.lang, want.old),
    new = hl.collect(f.new_buf, f.lang, want.new),
    index = f.index_buf and hl.collect(f.index_buf, f.lang, want.index),
  }
  for _, row in ipairs(job.rows) do
    local l = view.lines[row]
    for _, s in ipairs(segs[l.side][l.row] or {}) do
      -- `end_col == -1` marks a capture that continues past this row
      local end_col = s.end_col < 0 and #l.text or math.min(s.end_col, #l.text)
      if s.start_col < end_col then
        vim.api.nvim_buf_set_extmark(buf, ns_syntax, row - 1, s.start_col, {
          end_col = end_col,
          hl_group = s.hl_group,
          priority = s.priority,
        })
      end
    end
  end
end

--- The files in the order their syntax is filled in: the one the cursor is in,
--- then those below it, then those above. That puts what is on screen first
--- without asking the window what it shows, which it does not know until it has
--- been redrawn.
--- @param buf integer
--- @param view gitview.View
--- @return integer[]
local function fill_order(buf, view)
  local win = vim.fn.win_findbuf(buf)[1]
  local cursor = win and vim.api.nvim_win_get_cursor(win)[1] or 1
  local at = 1
  for i, f in ipairs(view.files) do
    if f.row <= cursor then
      at = i
    end
  end
  local order = {}
  for i = at, #view.files do
    order[#order + 1] = i
  end
  for i = at - 1, 1, -1 do
    order[#order + 1] = i
  end
  return order
end

--- Replay the syntax of every file onto `buf`, then free the ghost buffers.
---
--- The open rows come first and the folded ones after, since those are only
--- seen once the reader opens a fold. A large view gets even its open rows in
--- steps scheduled after the draw, so that its text is on screen before the
--- colors are; the folded rows always do, since they cover every unchanged line
--- of every file. A step finding that `buf` no longer shows the view gives up:
--- the view has been replaced, and its colors would land on someone else's rows.
---
--- The screen is redrawn explicitly, before the first step and after each one.
--- Neovim puts off its own redraw while an event is already waiting to run, and
--- a step's timer always is by then, so the text would otherwise appear only
--- together with the last of the colors.
--- @param buf integer
--- @param view gitview.View
local function fill_syntax(buf, view)
  local open, folded = rows_by_file(view)
  local jobs = {} --- @type gitview.FillJob[]
  local order = fill_order(buf, view)
  local open_rows = 0
  for _, file in ipairs(order) do
    jobs[#jobs + 1] = open[file]
    open_rows = open_rows + #open[file].rows
  end
  local first_folded = #jobs + 1
  for _, file in ipairs(order) do
    if #folded[file].rows > 0 then
      jobs[#jobs + 1] = folded[file]
    end
  end

  local next_job = 1
  if open_rows <= PROGRESSIVE_ROWS then
    for i = 1, first_folded - 1 do
      fill_file(buf, view, jobs[i])
    end
    next_job = first_folded
  end
  if next_job > #jobs then
    vlib.dispose(view)
    return
  end

  -- Until the last step, which is when the view is fully colored.
  local span = perf.start('syntax.background', { jobs = #jobs - next_job + 1 })
  local steps = 0
  local function step()
    if views[buf] ~= view then
      vlib.dispose(view)
      span:finish({ steps = steps, replaced = true })
      return
    end
    steps = steps + 1
    local deadline = vim.uv.hrtime() + STEP_BUDGET_MS * 1e6
    repeat
      fill_file(buf, view, jobs[next_job])
      next_job = next_job + 1
    until next_job > #jobs or vim.uv.hrtime() >= deadline
    vim.cmd.redraw()
    if next_job > #jobs then
      vlib.dispose(view)
      span:finish({ steps = steps })
    else
      -- A timer rather than `vim.schedule`: the event queue runs whatever is
      -- scheduled while it is being drained, so a chain of `vim.schedule`d
      -- steps would run back to back without letting a keystroke in.
      vim.defer_fn(step, 0)
    end
  end
  vim.cmd.redraw()
  vim.defer_fn(step, 0)
end

--- Replace whatever `buf` holds with `view`.
---
--- The view's ghost buffers are this function's to free from here on: its
--- syntax may still be being collected from them after it returns.
--- @param buf integer from `create_buffer`
--- @param view gitview.View
function M.draw(buf, view)
  -- Up to the text being on screen; `syntax.background` covers what is left.
  local span = perf.start('draw', { rows = #view.lines })
  M.ensure_highlights()
  vim.bo[buf].modifiable = true
  -- Both namespaces have to go: leaving either behind keeps marks from the
  -- previous view on rows the new one is shorter than.
  vim.api.nvim_buf_clear_namespace(buf, ns_syntax, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_diff, 0, -1)

  local folds = fold_states(buf)

  local texts = {}
  for i, l in ipairs(view.lines) do
    texts[i] = l.text
  end
  -- 'foldexpr' is evaluated while the lines are being replaced, so the view it
  -- reads has to be the new one by then.
  views[buf] = view
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  restore_folds(view, folds)

  -- 1. syntax, replayed from the ghost buffers: last, since it may be left for
  --    later. See `fill_syntax`.

  -- 2. full-line backgrounds: the diff colors, and the separator and file
  --    header lines, which are ordinary buffer lines so that a selection across
  --    them yanks what is on screen.
  --    `line_hl_group` would be simpler, but it is painted outside the extmark
  --    priority order, so the word-level highlights below would never show
  --    through. A range mark ending on the next row with `hl_eol` fills the rest
  --    of the screen line just as well and does obey priorities.
  for row0, l in ipairs(view.lines) do
    local line_hl = line_hl_of(l)
    if line_hl then
      vim.api.nvim_buf_set_extmark(buf, ns_diff, row0 - 1, 0, {
        end_row = row0,
        end_col = 0,
        hl_group = line_hl,
        hl_eol = true,
        -- below the syntax layer so that replayed foreground colors survive
        priority = 10,
      })
    end
  end

  -- 3. word-level highlights on paired change lines
  for _, pair in ipairs(dlib.change_pairs(view.lines)) do
    local del_row, add_row = pair[1], pair[2]
    local del_l, add_l = view.lines[del_row], view.lines[add_row]
    local old_text, new_text = del_l.text, add_l.text
    local or_, nr_ = worddiff.ranges(old_text, new_text)
    if worddiff.useful(old_text, new_text, or_, nr_) then
      for _, r in ipairs(or_) do
        vim.api.nvim_buf_set_extmark(buf, ns_diff, del_row - 1, r.start_col, {
          end_col = r.end_col,
          hl_group = text_hl_of(del_l),
          hl_mode = 'combine',
          priority = 200,
        })
      end
      for _, r in ipairs(nr_) do
        vim.api.nvim_buf_set_extmark(buf, ns_diff, add_row - 1, r.start_col, {
          end_col = r.end_col,
          hl_group = text_hl_of(add_l),
          hl_mode = 'combine',
          priority = 200,
        })
      end
    end
  end

  -- 4. the `+` and `-` graph of each stat row, colored as git colors it
  --    A path can hold a `|` of its own, so the graph is looked for after the
  --    last one; a binary file's `Bin 0 -> 3 bytes` has no graph to color.
  for row0, l in ipairs(view.lines) do
    local bar = l.kind == 'stat' and l.text:find('|[^|]*$')
    local at, graph
    if bar then
      at, graph = l.text:match('^|%s*%d+ ()([+-]+)$', bar)
    end
    if graph then
      for pattern, group in pairs(STAT_HL) do
        for s, e in graph:gmatch('()' .. pattern .. '()') do
          vim.api.nvim_buf_set_extmark(buf, ns_diff, row0 - 1, at + s - 2, {
            end_col = at + e - 2,
            hl_group = group,
            priority = 100,
          })
        end
      end
    end
  end

  -- 5. the rest of each file's header rule, which the gutter starts
  for _, f in ipairs(view.files) do
    vim.api.nvim_buf_set_extmark(buf, ns_diff, f.row - 1, 0, {
      virt_text = { { RULE, 'GitViewFileRule' } },
      virt_text_pos = 'eol',
      priority = 10,
    })
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  fill_syntax(buf, view)
  span:finish()
end

--- Replace whatever `buf` holds with a single line of text.
---
--- Some things a diff window has to show are not views: a binary file, a change
--- with no lines to it such as a pure rename, and nothing being selected at
--- all. The view is dropped with the text, so the gutter and the winbar fall
--- back to showing nothing rather than describing what was there before.
--- @param buf integer from `create_buffer`
--- @param text string
function M.notice(buf, text)
  -- A notice is painted with `GitViewSeparator`, so it is a first use of the
  -- groups just as much as `draw` is. Without this a session whose first
  -- selection has no view to show - a clean repository, a binary file - would
  -- draw the notice against a group nothing had defined yet.
  M.ensure_highlights()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns_syntax, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_diff, 0, -1)
  -- before the lines, so that 'foldexpr' does not fold them by the old view
  views[buf] = nil
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_buf_set_extmark(buf, ns_diff, 0, 0, {
    end_row = 1,
    end_col = 0,
    hl_group = 'GitViewSeparator',
    hl_eol = true,
    priority = 10,
  })
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

--- Make a buffer and draw a view in it. Callers that keep a buffer of their own
--- use `create_buffer` and `draw` apart.
--- @param view gitview.View
--- @return integer bufnr
function M.render(view)
  local buf = M.create_buffer()
  M.draw(buf, view)
  return buf
end

--- Width of the gutter: two four-digit line numbers and a sign, each followed
--- by a space. A mixed view puts a stage marker in front of the sign.
local BLANK_GUTTER = (' '):rep(12)
local BLANK_MIXED_GUTTER = (' '):rep(13)

--- `S` for a staged change, `I` for a line that only the index has.
local STAGE_MARK = { staged = 'S', index = 'I' }

--- A count as it fits in the gutter: as it is up to four digits, and cut down
--- to thousands or millions beyond that, so that each side of a header's count
--- stays within four characters after its sign. It is rounded down, which keeps
--- `999999` from becoming `1000k` and never makes a file look bigger than it is.
--- @param n integer
--- @return string
local function abbrev_count(n)
  if n < 10000 then
    return tostring(n)
  elseif n < 1000000 then
    return math.floor(n / 1000) .. 'k'
  end
  return math.floor(n / 1000000) .. 'M'
end

--- How much a commit changed, from the summary git ends its stat with, or nil
--- while its header has no stat yet.
--- @param view gitview.View
--- @return {files:integer, add:integer, del:integer}?
local function commit_size(view)
  local last = view.header_rows and view.lines[view.header_rows]
  if not (last and last.kind == 'stat') then
    return nil
  end
  local function count(pattern)
    return tonumber(last.text:match(pattern)) or 0
  end
  return {
    files = count('(%d+) files? changed'),
    add = count('(%d+) insertions?'),
    del = count('(%d+) deletions?'),
  }
end

--- A gutter ending with how many lines are added and deleted, right before the
--- text, where the eye already is and where a long line cannot run into it. The
--- count is at most `+9999 -9999`, which is as wide as the gutter leaves room
--- for, and `fill` pads it out to the gutter's width on its left.
--- @param view gitview.View
--- @param add integer
--- @param del integer
--- @param fill fun(cells: integer): string
--- @return string
local function count_gutter(view, add, del, fill)
  -- the last cell is the space that parts the gutter from the text
  local width = #(view.mixed and BLANK_MIXED_GUTTER or BLANK_GUTTER) - 1
  local parts, count = {}, {}
  if add > 0 then
    local text = '+' .. abbrev_count(add)
    parts[#parts + 1] = '%#GitViewStatAdd#' .. text
    count[#count + 1] = text
  end
  if del > 0 then
    local text = '-' .. abbrev_count(del)
    parts[#parts + 1] = '%#GitViewStatDelete#' .. text
    count[#count + 1] = text
  end
  local len = #table.concat(count, ' ')
  local pad, gap = width, ''
  if len > 0 then
    -- a space parts the padding from the count, if there is room left for one
    pad = math.max(width - len - 1, 0)
    gap = len < width and ' ' or ''
  end
  return fill(pad) .. gap .. table.concat(parts, ' ') .. ' '
end

--- @param cells integer
--- @return string
local function rule_fill(cells)
  return '%#GitViewFileRule#' .. RULE:sub(1, #'─' * cells)
end

--- What the gutter of each file's header shows, by row: the start of the rule,
--- and how many lines the file adds and deletes. Worked out once per view, as
--- 'statuscolumn' asks for it on every redraw.
--- @type table<gitview.View, table<integer, string>>
local header_gutter_cache = setmetatable({}, { __mode = 'k' })

--- @param view gitview.View
--- @return table<integer, string>
local function header_gutters(view)
  local cached = header_gutter_cache[view]
  if cached then
    return cached
  end
  local gutters = {}
  for i, s in ipairs(file_stats(view)) do
    gutters[view.files[i].row] = count_gutter(view, s.add, s.del, rule_fill)
  end
  header_gutter_cache[view] = gutters
  return gutters
end

--- Gutter is drawn through 'statuscolumn' rather than written into the buffer so
--- that the line numbers stay out of a yank.
--- @return string
function M.statuscolumn()
  local win = vim.g.statusline_winid
  local view = views[vim.api.nvim_win_get_buf(win)]
  -- A window that inherited 'statuscolumn' from a diff window is showing another
  -- buffer, which has no gutter: drawing blanks would leave it an empty column.
  if not view then
    return ''
  end
  local blank = view.mixed and BLANK_MIXED_GUTTER or BLANK_GUTTER
  -- 'statuscolumn' is evaluated for every screen line, so a wrapped line must
  -- not repeat the numbers of the buffer line it continues.
  if vim.v.virtnum ~= 0 then
    return blank
  end
  local l = view.lines[vim.v.lnum]
  if l and l.kind == 'file' then
    return header_gutters(view)[vim.v.lnum]
  end
  local lnum = vim.v.lnum
  -- A folded commit header ends with the commit's count, as a file's header
  -- does. Opened, its stat says the same more exactly.
  if view.header_rows and lnum == HEADER_FOLD_ROW then
    local size = commit_size(view)
    if size and vim.api.nvim_win_call(win, function()
      return vim.fn.foldclosed(lnum) ~= -1
    end) then
      return count_gutter(view, size.add, size.del, function(cells)
        return (' '):rep(cells)
      end)
    end
    return blank
  end
  -- file headers and the blanks between files stand for no source line and so
  -- have no numbers to show
  if not l or not dlib.source_kinds[l.kind] then
    return blank
  end
  -- A closed fold is drawn as its first row, and stands for all of them.
  if l.folded and vim.api.nvim_win_call(win, function()
    return vim.fn.foldclosed(lnum) ~= -1
  end) then
    return blank
  end
  local function num(n)
    return n and string.format('%4d', n) or '    '
  end
  local mark = ''
  if view.mixed then
    mark = '%#GitViewStagedSign#' .. (STAGE_MARK[l.stage] or ' ') .. '%#GitViewNewLnum#'
  end
  return string.format(
    '%%#GitViewOldLnum#%s %%#GitViewNewLnum#%s %s%s ',
    num(l.old_lnum),
    num(l.new_lnum),
    mark,
    SIGN[l.kind]
  )
end

--- What a view compares, for the winbar, with its shas colored as the commits
--- pane colors them.
---
--- The shas are found in the first word, which is where every label puts them:
--- `<sha> <subject>`, `<sha>^..<sha>`, `<sha>^..working tree`. A subject is
--- left alone, however much of it happens to be hexadecimal.
--- @param rev string
--- @return string
local function rev_statusline(rev)
  local word, rest = rev:match('^(%S*)(.*)$')
  local out, at = {}, 1
  for from, hex, to in word:gmatch('()%f[%w](%x+)%f[%W]()') do
    if #hex >= 4 then
      out[#out + 1] = util.escape_statusline(word:sub(at, from - 1))
      out[#out + 1] = '%#GitViewCommitSha#' .. hex .. '%#GitViewFileHeader#'
      at = to
    end
  end
  out[#out + 1] = util.escape_statusline(word:sub(at) .. rest)
  return table.concat(out)
end

--- Names the file the cursor is in. Recomputed on every redraw, so it keeps the
--- file identifiable once its header line has scrolled off.
--- @return string
function M.winbar()
  local win = vim.g.statusline_winid
  local view = views[vim.api.nvim_win_get_buf(win)]
  if not view then
    return ''
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  -- Headers are in ascending order, so the last one at or above the cursor is
  -- the file it is in and there is nothing after it worth looking at. Above the
  -- first one is a commit's header, which is in no file.
  local file
  for _, f in ipairs(view.files) do
    if f.row > row then
      break
    end
    file = f
  end

  local head = file and (' %s @ '):format(file.label) or ' '
  local tail = ''
  if #view.files > 1 then
    tail = tail .. ('   [%d files]'):format(#view.files)
  end
  if view.note then
    tail = tail .. '   ' .. view.note
  end
  return '%#GitViewFileHeader#'
    .. util.escape_statusline(head)
    .. rev_statusline(view.rev)
    .. util.escape_statusline(tail)
end

--- Folds a commit's header below its subject into one line, and each run of
--- unchanged lines away from a change into another.
--- @return string
function M.foldexpr()
  -- Evaluated with the window being folded made current, whichever it is.
  local view = views[vim.api.nvim_get_current_buf()]
  if not view then
    return '0'
  end
  local lnum = vim.v.lnum
  local n = view.header_rows
  if n and lnum <= n then
    if lnum < HEADER_FOLD_ROW then
      return '0'
    end
    return lnum == HEADER_FOLD_ROW and '>1' or '1'
  end
  local l, prev = view.lines[lnum], view.lines[lnum - 1]
  if not (l and l.folded) then
    return '0'
  end
  -- Two runs are never adjacent, but a run has to start a fold of its own
  -- rather than continue whatever the row above it was in.
  return (prev and prev.folded) and '1' or '>1'
end

--- The first line of a folded run that is not blank, as chunks grouped by the
--- syntax replayed onto it, cut to `width` display cells. Tabs are expanded
--- here, since how wide one is has to be known to cut the line anyway.
---
--- The syntax of a folded row is filled in after the rest of the view, so a run
--- shown before then reads as plain text, and is redrawn once it is colored.
--- @param buf integer
--- @param view gitview.View
--- @param first integer 1-based first row of the run
--- @param last integer
--- @param width integer
--- @return {text: string, group: string?}[]
local function first_line_chunks(buf, view, first, last, width)
  local row
  for r = first, last do
    if view.lines[r].text:find('%S') then
      row = r
      break
    end
  end
  if not row then
    return {}
  end
  local text = view.lines[row].text

  -- Which group paints each byte: the mark of the highest priority, and of two
  -- at the same priority the one set later, as when they are drawn.
  local marks = vim.api.nvim_buf_get_extmarks(
    buf,
    ns_syntax,
    { row - 1, 0 },
    { row - 1, -1 },
    { details = true }
  )
  table.sort(marks, function(a, b)
    if a[4].priority ~= b[4].priority then
      return a[4].priority < b[4].priority
    end
    return a[1] < b[1]
  end)
  local group = {}
  for _, m in ipairs(marks) do
    for byte = m[3] + 1, m[4].end_col or #text do
      group[byte] = m[4].hl_group
    end
  end

  local tabstop = vim.bo[buf].tabstop
  local chunks, col = {}, 0
  for _, at in ipairs(vim.str_utf_pos(text)) do
    local char = text:sub(at, at + vim.str_utf_end(text, at))
    local cells
    if char == '\t' then
      cells = tabstop - col % tabstop
      char = (' '):rep(cells)
    else
      cells = vim.api.nvim_strwidth(char)
    end
    if col + cells > width then
      break
    end
    local prev = chunks[#chunks]
    if prev and prev.group == group[at] then
      prev.text = prev.text .. char
    else
      chunks[#chunks + 1] = { text = char, group = group[at] }
    end
    col = col + cells
  end
  return chunks
end

--- A folded header reads as who wrote the commit how long ago and how many
--- files it changed, and a folded run of unchanged lines as its first line that
--- is not blank and how many lines it holds. Whatever room is left is filled
--- with 'fillchars' fold.
---
--- Each chunk's group is drawn over `Folded`, so the code keeps its colors on
--- the fold's background.
--- @return string|[string, string][]
function M.foldtext()
  local buf = vim.api.nvim_get_current_buf()
  local view = views[buf]
  if not view then
    return vim.fn.foldtext()
  end
  if not view.header_rows or vim.v.foldstart > view.header_rows then
    local first, last = vim.v.foldstart, vim.v.foldend
    local label = ('  %s '):format(util.counted(last - first + 1, 'line'))
    local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
    local width = info.width - info.textoff - vim.api.nvim_strwidth(label)
    local out = {}
    for _, c in ipairs(first_line_chunks(buf, view, first, last, width)) do
      out[#out + 1] = { c.text, c.group or 'GitViewSeparator' }
    end
    out[#out + 1] = { label, 'GitViewSeparator' }
    return out
  end

  -- how many lines it changed is in the gutter
  local author = view.lines[HEADER_FOLD_ROW]
  local text = '\u{25b8} ' .. (author.byline or author.text)
  local size = commit_size(view)
  if size and size.files > 0 then
    text = text .. '   ' .. util.counted(size.files, 'file')
  end
  -- a space between the text and the fill, as the label of a run has
  return { { text .. ' ', 'GitViewCommitAuthor' } }
end

--- @param win integer
--- @param buf integer
function M.configure_window(win, buf)
  util.configure_window_options(win, {
    winbar = '%!v:lua.require("gitview.diff.render").winbar()',
    statuscolumn = '%!v:lua.require("gitview.diff.render").statuscolumn()',
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    wrap = false,
    cursorline = false,
    foldmethod = 'expr',
    foldexpr = 'v:lua.require("gitview.diff.render").foldexpr()',
    foldtext = 'v:lua.require("gitview.diff.render").foldtext()',
    foldenable = true,
    -- a commit's header and the unchanged lines start folded: the changes are
    -- what is being read
    foldlevel = 0,
    -- A header's fold can be as short as its author. A fold no longer than
    -- 'foldminlines' stays open, and would be carried over to the next commit
    -- as the reader's choice.
    foldminlines = 0,
    foldcolumn = '0',
  })
end

return M
