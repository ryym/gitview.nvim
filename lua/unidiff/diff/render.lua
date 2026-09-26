local hl = require('unidiff.diff.highlight')
local util = require('unidiff.util')
local worddiff = require('unidiff.diff.worddiff')
local dlib = require('unidiff.diff.lines')

local M = {}

local ns_syntax = vim.api.nvim_create_namespace('unidiff.syntax')
local ns_diff = vim.api.nvim_create_namespace('unidiff.diff')

--- @type table<integer, unidiff.View>
M.views = {}

--- @class unidiff.File
--- @field path string absolute path in the working tree
--- @field label string what the header shows
--- @field old_buf integer ghost buffer holding the old version
--- @field new_buf integer ghost buffer holding the new version
--- @field index_buf integer? ghost buffer holding the index version, mixed views only
--- @field lang string language for highlight collection
--- @field row integer 1-based row of this file's header line

--- @class unidiff.View
--- @field lines unidiff.Line[]
--- @field files unidiff.File[]
--- @field hunk_rows integer[] rows worth jumping between, ascending
--- @field file_rows integer[] the rows of `files`' header lines, ascending
--- @field rev string
--- @field note string? extra text for the winbar, e.g. skipped files
--- @field mixed boolean? staged and unstaged changes in one view; see unidiff.diff.mixed
--- @field historical boolean? the versions compared are both committed, so the
---        line numbers are not the working tree's

--- Highlight groups are defined on first use rather than from `setup()`, so a
--- diff opened without any configuration still gets its colors. Doing it lazily
--- also means the colorscheme is loaded by the time `DiffAdd` is read.
local highlights = util.highlights('unidiff.highlights', function(set)
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
  set('UnidiffAdd', add)
  set('UnidiffDelete', del)
  set('UnidiffAddText', scale(add, 1.4))
  set('UnidiffDeleteText', scale(del, 1.4))
  -- Staged changes in a mixed view are the same hues, faded: they are settled,
  -- and what is still unstaged is what needs attention. The gutter marks them
  -- too, since 256-color terminals get no fading.
  set('UnidiffStagedAdd', scale(add, 0.5))
  set('UnidiffStagedDelete', scale(del, 0.5))
  set('UnidiffStagedAddText', scale(add, 0.9))
  set('UnidiffStagedDeleteText', scale(del, 0.9))
  set('UnidiffStagedSign', { link = 'Special' })
  set('UnidiffOldLnum', { link = 'LineNr' })
  set('UnidiffNewLnum', { link = 'LineNr' })
  set('UnidiffSeparator', { link = 'Folded' })
  set('UnidiffFileHeader', { link = 'Title' })
end)

M.setup_highlights = highlights.apply
M.ensure_highlights = highlights.ensure
--- Testing hook: forget that the groups were ever defined.
M.ensure_highlights_reset = highlights.forget

local SIGN = { add = '+', del = '-', context = ' ' }
local LINE_HL = {
  add = 'UnidiffAdd',
  del = 'UnidiffDelete',
  gap = 'UnidiffSeparator',
  file = 'UnidiffFileHeader',
}
local TEXT_HL = { add = 'UnidiffAddText', del = 'UnidiffDeleteText' }
local STAGED_LINE_HL = { add = 'UnidiffStagedAdd', del = 'UnidiffStagedDelete' }
local STAGED_TEXT_HL = { add = 'UnidiffStagedAddText', del = 'UnidiffStagedDeleteText' }

--- @param l unidiff.Line
--- @return string?
local function line_hl_of(l)
  return l.stage == 'staged' and STAGED_LINE_HL[l.kind] or LINE_HL[l.kind]
end

--- @param l unidiff.Line
--- @return string
local function text_hl_of(l)
  return l.stage == 'staged' and STAGED_TEXT_HL[l.kind] or TEXT_HL[l.kind]
end

--- A buffer to draw diffs in. It is made once and drawn into repeatedly: a view
--- that showed one file can be replaced by one showing another without swapping
--- the buffer out of its window, which would fire the Buf* autocommands on every
--- keystroke of a file list.
--- @return integer bufnr
function M.create_buffer()
  return util.scratch_buffer('unidiff', M.views)
end

--- Replace whatever `buf` holds with `view`.
--- @param buf integer from `create_buffer`
--- @param view unidiff.View
function M.draw(buf, view)
  M.ensure_highlights()
  vim.bo[buf].modifiable = true
  -- Both namespaces have to go: leaving either behind keeps marks from the
  -- previous view on rows the new one is shorter than.
  vim.api.nvim_buf_clear_namespace(buf, ns_syntax, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_diff, 0, -1)

  local texts = {}
  for i, l in ipairs(view.lines) do
    texts[i] = l.text
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)

  -- Only a fraction of each version ends up on screen. The legacy syntax path
  -- probes byte by byte, so telling it which rows matter keeps that bounded by
  -- the size of the diff rather than the size of the file.
  local want = {}
  for i = 1, #view.files do
    want[i] = { old = {}, new = {}, index = {} }
  end
  for _, l in ipairs(view.lines) do
    if dlib.source_kinds[l.kind] then
      want[l.file][l.side][l.row] = true
    end
  end

  local segs = {}
  for i, f in ipairs(view.files) do
    segs[i] = {
      old = hl.collect(f.old_buf, f.lang, want[i].old),
      new = hl.collect(f.new_buf, f.lang, want[i].new),
      index = f.index_buf and hl.collect(f.index_buf, f.lang, want[i].index),
    }
  end

  -- 1. syntax, replayed from the ghost buffers
  for row0, l in ipairs(view.lines) do
    local row = row0 - 1
    for _, s in ipairs(dlib.source_kinds[l.kind] and segs[l.file][l.side][l.row] or {}) do
      -- `end_col == -1` marks a capture that continues past this row
      local end_col = s.end_col < 0 and #l.text or math.min(s.end_col, #l.text)
      if s.start_col < end_col then
        vim.api.nvim_buf_set_extmark(buf, ns_syntax, row, s.start_col, {
          end_col = end_col,
          hl_group = s.hl_group,
          priority = s.priority,
        })
      end
    end
  end

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

  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  M.views[buf] = view
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
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns_syntax, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_diff, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_buf_set_extmark(buf, ns_diff, 0, 0, {
    end_row = 1,
    end_col = 0,
    hl_group = 'UnidiffSeparator',
    hl_eol = true,
    priority = 10,
  })
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  M.views[buf] = nil
end

--- Make a buffer and draw a view in it. Callers that keep a buffer of their own
--- use `create_buffer` and `draw` apart.
--- @param view unidiff.View
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

--- Gutter is drawn through 'statuscolumn' rather than written into the buffer so
--- that the line numbers stay out of a yank.
--- @return string
function M.statuscolumn()
  local win = vim.g.statusline_winid
  local view = M.views[vim.api.nvim_win_get_buf(win)]
  local blank = view and view.mixed and BLANK_MIXED_GUTTER or BLANK_GUTTER
  -- 'statuscolumn' is evaluated for every screen line, so a wrapped line must
  -- not repeat the numbers of the buffer line it continues.
  if vim.v.virtnum ~= 0 then
    return blank
  end
  local l = view and view.lines[vim.v.lnum]
  -- separators, file headers and the blanks between files stand for no source
  -- line and so have no numbers to show
  if not l or not dlib.source_kinds[l.kind] then
    return blank
  end
  local function num(n)
    return n and string.format('%4d', n) or '    '
  end
  local mark = ''
  if view.mixed then
    mark = '%#UnidiffStagedSign#' .. (STAGE_MARK[l.stage] or ' ') .. '%#UnidiffNewLnum#'
  end
  return string.format(
    '%%#UnidiffOldLnum#%s %%#UnidiffNewLnum#%s %s%s ',
    num(l.old_lnum),
    num(l.new_lnum),
    mark,
    SIGN[l.kind]
  )
end

--- Names the file the cursor is in. Recomputed on every redraw, so it keeps the
--- file identifiable once its header line has scrolled off.
--- @return string
function M.winbar()
  local win = vim.g.statusline_winid
  local view = M.views[vim.api.nvim_win_get_buf(win)]
  if not view then
    return ''
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local file = view.files[1]
  for _, f in ipairs(view.files) do
    if f.row <= row then
      file = f
    end
  end
  if not file then
    return ''
  end

  local text = (' %s @ %s'):format(file.label, view.rev)
  if #view.files > 1 then
    text = text .. ('   [%d files]'):format(#view.files)
  end
  if view.note then
    text = text .. '   ' .. view.note
  end
  return '%#UnidiffFileHeader#' .. util.escape_statusline(text)
end

--- @param win integer
--- @param buf integer
function M.configure_window(win, buf)
  vim.wo[win].winbar = '%!v:lua.require("unidiff.diff.render").winbar()'
  vim.wo[win].statuscolumn = '%!v:lua.require("unidiff.diff.render").statuscolumn()'
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
end

return M
