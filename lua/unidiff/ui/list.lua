--- The file list: what it looks like, and which entry each row stands for.
---
--- As in a diff buffer, the text is the thing itself and the markers around it
--- are drawn rather than written. Here that means the buffer holds paths and
--- nothing else, so yanking a line gives a path that can be pasted somewhere
--- useful, while the two status letters are painted by `'statuscolumn'`.
local status = require('unidiff.status')

local M = {}

--- @class unidiff.ListContent
--- @field lines string[] one per buffer row
--- @field rows table<integer, integer> 1-based row -> index into the entries;
---        a row standing for no entry, such as the empty notice, is absent

--- Shown instead of the list when there is nothing uncommitted. It is a row of
--- the buffer, so it has no entry and no status letters.
M.EMPTY_NOTICE = 'no uncommitted changes'

--- @param entries unidiff.StatusEntry[]
--- @return unidiff.ListContent
function M.content(entries)
  if #entries == 0 then
    return { lines = { M.EMPTY_NOTICE }, rows = {} }
  end
  local lines, rows = {}, {}
  for i, e in ipairs(entries) do
    lines[i] = status.label(e)
    rows[i] = i
  end
  return { lines = lines, rows = rows }
end

local highlights_ready = false

--- Status letters are foreground colors, unlike the diff backgrounds, so they
--- are taken from the groups Neovim already defines for exactly this: `Added`,
--- `Changed` and `Comment`. Defining any of them yourself takes precedence.
function M.setup_highlights()
  local set = function(name, val)
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', val, { default = true }))
  end
  set('UnidiffStatusStaged', { link = 'Added' })
  set('UnidiffStatusUnstaged', { link = 'Changed' })
  set('UnidiffStatusUntracked', { link = 'Comment' })
  set('UnidiffStatusHeader', { link = 'Title' })

  if not highlights_ready then
    highlights_ready = true
    vim.api.nvim_create_autocmd('ColorScheme', {
      group = vim.api.nvim_create_augroup('unidiff.ui.highlights', { clear = true }),
      callback = function()
        M.setup_highlights()
      end,
    })
  end
end

--- Testing hook: forget that the groups were ever defined.
function M.ensure_highlights_reset()
  highlights_ready = false
end

--- Sessions by the buffer holding their list, so that `'statuscolumn'` can find
--- the entry a screen line belongs to. Filled in by `ui.session`.
--- @type table<integer, {root:string, entries:unidiff.StatusEntry[], rows:table<integer,integer>}>
M.state = {}

--- Two status letters and a space. A row with no entry keeps the width so the
--- paths stay in one column.
local BLANK_GUTTER = '   '

--- @return string
function M.statuscolumn()
  local win = vim.g.statusline_winid
  local state = M.state[vim.api.nvim_win_get_buf(win)]
  if vim.v.virtnum ~= 0 or not state then
    return BLANK_GUTTER
  end
  local entry = state.entries[state.rows[vim.v.lnum]]
  if not entry then
    return BLANK_GUTTER
  end
  if entry.index_status == '?' then
    return '%#UnidiffStatusUntracked#?? '
  end
  return ('%%#UnidiffStatusStaged#%s%%#UnidiffStatusUnstaged#%s '):format(
    entry.index_status,
    entry.worktree_status
  )
end

--- Names the repository and how much is uncommitted.
--- @return string
function M.winbar()
  local win = vim.g.statusline_winid
  local state = M.state[vim.api.nvim_win_get_buf(win)]
  if not state then
    return ''
  end
  local text = (' %s   %d file%s'):format(
    vim.fs.basename(state.root),
    #state.entries,
    #state.entries == 1 and '' or 's'
  )
  return '%#UnidiffStatusHeader#' .. text:gsub('%%', '%%%%')
end

--- @return integer bufnr
function M.create_buffer()
  M.setup_highlights()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'unidiffstatus'
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      M.state[buf] = nil
    end,
  })
  return buf
end

--- @param buf integer from `create_buffer`
--- @param root string repository root
--- @param entries unidiff.StatusEntry[]
function M.draw(buf, root, entries)
  local content = M.content(entries)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  M.state[buf] = { root = root, entries = entries, rows = content.rows }
end

--- @param win integer
function M.configure_window(win)
  vim.wo[win].winbar = '%!v:lua.require("unidiff.ui.list").winbar()'
  vim.wo[win].statuscolumn = '%!v:lua.require("unidiff.ui.list").statuscolumn()'
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
end

--- Which entry a row stands for, if it stands for one.
--- @param buf integer
--- @param row integer 1-based
--- @return integer? index into the entries
function M.index_at(buf, row)
  local state = M.state[buf]
  return state and state.rows[row] or nil
end

--- The entry a row stands for, if it stands for one.
--- @param buf integer
--- @param row integer 1-based
--- @return unidiff.StatusEntry?
function M.entry_at(buf, row)
  local index = M.index_at(buf, row)
  local state = M.state[buf]
  return index and state.entries[index] or nil
end

--- Where an entry is shown. The reverse of `index_at`, for moving the cursor to
--- a file chosen from somewhere other than the list itself.
--- @param buf integer
--- @param index integer into the entries
--- @return integer? row 1-based
function M.row_of(buf, index)
  local state = M.state[buf]
  if not state then
    return nil
  end
  for row, i in pairs(state.rows) do
    if i == index then
      return row
    end
  end
  return nil
end

return M
