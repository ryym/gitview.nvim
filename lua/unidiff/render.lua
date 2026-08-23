local hl = require('unidiff.highlight')
local worddiff = require('unidiff.worddiff')
local dlib = require('unidiff.diff')

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
--- @field lang string language for highlight collection
--- @field row integer 1-based row of this file's first line

--- @class unidiff.View
--- @field lines unidiff.Line[]
--- @field files unidiff.File[]
--- @field hunk_rows integer[]
--- @field gaps {row:integer, count:integer}[]
--- @field rev string
--- @field note string? extra text for the winbar, e.g. skipped files

function M.setup_highlights()
  local set = function(name, val)
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', val, { default = true }))
  end

  --- Diff groups are taken background-only. Colorschemes give DiffAdd/DiffDelete
  --- a foreground as well, and a line highlight that carries one would repaint
  --- every character, erasing the syntax colors we just replayed.
  --- @param name string
  --- @param fallback string
  local function bg_only(name, fallback)
    local h = vim.api.nvim_get_hl(0, { name = name, link = false })
    return { bg = h.bg or tonumber(fallback:sub(2), 16), ctermbg = h.ctermbg }
  end

  --- Word-level highlights must stay recognisably "the add color" / "the delete
  --- color", so they are the same hue pushed further away from the normal
  --- background rather than a third, unrelated color.
  --- @param spec table result of bg_only
  local function intensify(spec)
    local base = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg
    if not spec.bg or not base then
      return spec
    end
    local out = 0
    for _, shift in ipairs({ 16, 8, 0 }) do
      local b = bit.band(bit.rshift(base, shift), 0xff)
      local c = bit.band(bit.rshift(spec.bg, shift), 0xff)
      local v = math.max(0, math.min(255, math.floor(b + (c - b) * 2.2)))
      out = out + bit.lshift(v, shift)
    end
    return { bg = out }
  end

  local add = bg_only('DiffAdd', '#20301e')
  local del = bg_only('DiffDelete', '#3a1f1c')
  set('UnidiffAdd', add)
  set('UnidiffDelete', del)
  set('UnidiffAddText', intensify(add))
  set('UnidiffDeleteText', intensify(del))
  set('UnidiffOldLnum', { link = 'LineNr' })
  set('UnidiffNewLnum', { link = 'LineNr' })
  set('UnidiffSeparator', { link = 'Folded' })
  set('UnidiffFileHeader', { link = 'Title' })
end

local SIGN = { add = '+', del = '-', context = ' ' }
local LINE_HL = { add = 'UnidiffAdd', del = 'UnidiffDelete' }
local TEXT_HL = { add = 'UnidiffAddText', del = 'UnidiffDeleteText' }

--- @param view unidiff.View
--- @return integer bufnr
function M.render(view)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'unidiff'

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
    want[i] = { old = {}, new = {} }
  end
  for _, l in ipairs(view.lines) do
    want[l.file][l.side][l.row] = true
  end

  local segs = {}
  for i, f in ipairs(view.files) do
    segs[i] = {
      old = hl.collect(f.old_buf, f.lang, want[i].old),
      new = hl.collect(f.new_buf, f.lang, want[i].new),
    }
  end

  -- 1. syntax, replayed from the ghost buffers
  for row0, l in ipairs(view.lines) do
    local row = row0 - 1
    for _, s in ipairs(segs[l.file][l.side][l.row] or {}) do
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

  -- 2. diff line backgrounds.
  --    `line_hl_group` would be simpler, but it is painted outside the extmark
  --    priority order, so the word-level highlights below would never show
  --    through. A range mark ending on the next row with `hl_eol` fills the rest
  --    of the screen line just as well and does obey priorities.
  for row0, l in ipairs(view.lines) do
    local line_hl = LINE_HL[l.kind]
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
    local old_text, new_text = view.lines[del_row].text, view.lines[add_row].text
    local or_, nr_ = worddiff.ranges(old_text, new_text)
    if worddiff.useful(old_text, new_text, or_, nr_) then
      for _, r in ipairs(or_) do
        vim.api.nvim_buf_set_extmark(buf, ns_diff, del_row - 1, r.start_col, {
          end_col = r.end_col,
          hl_group = TEXT_HL.del,
          hl_mode = 'combine',
          priority = 200,
        })
      end
      for _, r in ipairs(nr_) do
        vim.api.nvim_buf_set_extmark(buf, ns_diff, add_row - 1, r.start_col, {
          end_col = r.end_col,
          hl_group = TEXT_HL.add,
          hl_mode = 'combine',
          priority = 200,
        })
      end
    end
  end

  -- 4. separators for the ranges we skipped, as virtual lines so that yanking
  --    the buffer still yields nothing but source text
  for _, gap in ipairs(view.gaps or {}) do
    -- Neovim does not render `virt_lines_above` on the first line, so a gap that
    -- would sit there is reported in the winbar instead (see configure_window).
    if gap.row > 1 then
      local above = gap.row <= #view.lines
      vim.api.nvim_buf_set_extmark(buf, ns_diff, above and gap.row - 1 or #view.lines - 1, 0, {
        virt_lines = { { { M.gap_label(gap.count), 'UnidiffSeparator' } } },
        virt_lines_above = above,
      })
    end
  end

  -- 5. file headers, also virtual. The first file has no row to hang above, so
  --    the winbar names whichever file the cursor is in instead.
  for i, f in ipairs(view.files) do
    if i > 1 and f.row > 1 then
      vim.api.nvim_buf_set_extmark(buf, ns_diff, f.row - 1, 0, {
        virt_lines = {
          { { '', 'UnidiffSeparator' } },
          { { ' ' .. f.label .. ' ', 'UnidiffFileHeader' } },
        },
        virt_lines_above = true,
      })
    end
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  M.views[buf] = view

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      M.views[buf] = nil
    end,
  })

  return buf
end

--- Gutter is drawn through 'statuscolumn' rather than written into the buffer so
--- that visual selection and yank return the source text alone.
--- @return string
function M.statuscolumn()
  -- 'statuscolumn' is evaluated for virtual and wrapped lines too; those must
  -- not repeat the line numbers of the real line they hang off.
  if vim.v.virtnum ~= 0 then
    return '           '
  end
  local win = vim.g.statusline_winid
  local buf = vim.api.nvim_win_get_buf(win)
  local view = M.views[buf]
  local l = view and view.lines[vim.v.lnum]
  if not l then
    return '     '
  end
  local function num(n)
    return n and string.format('%4d', n) or '    '
  end
  return string.format(
    '%%#UnidiffOldLnum#%s %%#UnidiffNewLnum#%s %s ',
    num(l.old_lnum),
    num(l.new_lnum),
    SIGN[l.kind]
  )
end

--- @param count integer
--- @return string
function M.gap_label(count)
  local dots = ('\u{00b7}'):rep(4)
  return ('%s %d unchanged line%s %s'):format(dots, count, count == 1 and '' or 's', dots)
end

--- Names the file the cursor is in. Recomputed on every redraw, so it doubles
--- as the header for the first file, which cannot carry a virtual line above it.
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
  local lead = view.gaps[1]
  if lead and lead.row == 1 and row <= (view.files[2] and view.files[2].row or math.huge) then
    text = text .. '   ' .. M.gap_label(lead.count) .. ' above'
  end
  return '%#UnidiffFileHeader#' .. text:gsub('%%', '%%%%')
end

--- @param win integer
--- @param buf integer
function M.configure_window(win, buf)
  vim.wo[win].winbar = '%!v:lua.require("unidiff.render").winbar()'
  vim.wo[win].statuscolumn = '%!v:lua.require("unidiff.render").statuscolumn()'
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
end

return M
