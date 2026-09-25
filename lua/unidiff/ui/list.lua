--- The file list: what it looks like, and which entry each row stands for.
---
--- As in a diff buffer, the text is the thing itself and the markers around it
--- are drawn rather than written. Here that means the buffer holds paths and
--- nothing else, so yanking a line gives a path that can be pasted somewhere
--- useful, while the two status letters are painted by `'statuscolumn'`.
local status = require('unidiff.status')

local M = {}

local ns = vim.api.nvim_create_namespace('unidiff.ui.list')

--- @class unidiff.ListScope the commit the list is looking into, in place of
--- the uncommitted changes
--- @field commit unidiff.Commit
--- @field changes unidiff.Change[] what it changed

--- @class unidiff.ListModel what the list is showing
--- @field root string repository root
--- @field entries unidiff.StatusEntry[]? the uncommitted changes
--- @field commits unidiff.Commit[]? the tail of the history
--- @field scope unidiff.ListScope? shown instead of both of the above

--- @class unidiff.ListTarget what a row stands for
--- @field kind 'file'|'commit'|'commit_file'
--- @field index integer into the entries, the commits, or the scope's changes

--- @class unidiff.ListRow
--- @field text string the buffer line, which is the thing itself
--- @field gutter string? what `'statuscolumn'` draws, highlight groups included
--- @field target unidiff.ListTarget? absent on a row standing for nothing
--- @field header boolean? a section label rather than content

--- Shown instead of the list when there is nothing uncommitted. It is a row of
--- the buffer, so it has no entry and no status letters.
M.EMPTY_NOTICE = 'no uncommitted changes'

--- Names the section below it. Like the empty notice it stands for nothing, so
--- nothing resolves it to an entry or a commit.
M.COMMITS_HEADER = 'commits'

--- Shown in place of the file list of a commit that changed nothing, which
--- `git commit --allow-empty` makes.
M.EMPTY_COMMIT_NOTICE = 'this commit changed nothing'

--- Two status letters and a space. A row with no entry keeps the width so the
--- paths stay in one column.
local BLANK_GUTTER = '   '

--- The gutter is computed when the row is built rather than when the screen
--- line is drawn, because rows no longer all stand for the same kind of thing:
--- an entry has two status letters, a commit has none, and `'statuscolumn'`
--- would otherwise have to know about every kind.
--- @param e unidiff.StatusEntry
--- @return string
local function gutter_of(e)
  if e.index_status == '?' then
    return '%#UnidiffStatusUntracked#?? '
  end
  return ('%%#UnidiffStatusStaged#%s%%#UnidiffStatusUnstaged#%s '):format(
    e.index_status,
    e.worktree_status
  )
end

--- The files one commit changed, in place of the whole list.
---
--- A commit's changes and the uncommitted entries are different shapes, so they
--- are never mixed into one buffer: looking into a commit replaces the list
--- rather than extending it.
--- @param scope unidiff.ListScope
--- @return unidiff.ListRow[]
local function scope_rows(scope)
  local rows = {
    { text = ('%s %s'):format(scope.commit.sha, scope.commit.subject), header = true },
  }
  if #scope.changes == 0 then
    rows[#rows + 1] = { text = M.EMPTY_COMMIT_NOTICE }
    return rows
  end
  for i, c in ipairs(scope.changes) do
    rows[#rows + 1] = {
      text = status.change_label(c),
      -- One letter, in the color the list already uses for a settled change,
      -- padded to the width the two letters of an entry take.
      gutter = ('%%#UnidiffStatusStaged#%s  '):format(c.status),
      target = { kind = 'commit_file', index = i },
    }
  end
  return rows
end

--- @param model unidiff.ListModel
--- @return unidiff.ListRow[]
function M.content(model)
  if model.scope then
    return scope_rows(model.scope)
  end
  local rows = {}
  local function add(row)
    rows[#rows + 1] = row
  end

  local entries = model.entries or {}
  if #entries == 0 then
    add({ text = M.EMPTY_NOTICE })
  else
    for i, e in ipairs(entries) do
      add({
        text = status.label(e),
        gutter = gutter_of(e),
        target = { kind = 'file', index = i },
      })
    end
  end

  for i, c in ipairs(model.commits or {}) do
    if i == 1 then
      -- A blank row keeps the header off the last file, the way a view
      -- separates one file from the next.
      add({ text = '' })
      add({ text = M.COMMITS_HEADER, header = true })
    end
    add({
      text = ('%s %s'):format(c.sha, c.subject),
      target = { kind = 'commit', index = i },
    })
  end
  return rows
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
--- what a screen line belongs to. Filled in by `ui.session`.
--- @type table<integer, unidiff.ListModel|{rows:unidiff.ListRow[]}>
M.state = {}

--- @return string
function M.statuscolumn()
  local win = vim.g.statusline_winid
  local state = M.state[vim.api.nvim_win_get_buf(win)]
  if vim.v.virtnum ~= 0 or not state then
    return BLANK_GUTTER
  end
  local row = state.rows[vim.v.lnum]
  return row and row.gutter or BLANK_GUTTER
end

--- Names the repository and how much it is showing.
--- @return string
function M.winbar()
  local win = vim.g.statusline_winid
  local state = M.state[vim.api.nvim_win_get_buf(win)]
  if not state then
    return ''
  end
  local count = state.scope and #state.scope.changes or #state.entries
  local text = (' %s%s   %d file%s'):format(
    vim.fs.basename(state.root),
    state.scope and '   ' .. state.scope.commit.sha or '',
    count,
    count == 1 and '' or 's'
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
--- @param model unidiff.ListModel
function M.draw(buf, model)
  local rows = M.content(model)
  local texts = {}
  for i, r in ipairs(rows) do
    texts[i] = r.text
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  for i, r in ipairs(rows) do
    if r.header then
      -- Only the label is highlighted, not the rest of the line: there is no
      -- row after it to end an `hl_eol` range on when the header is last.
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        end_row = i - 1,
        end_col = #r.text,
        hl_group = 'UnidiffStatusHeader',
      })
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  M.state[buf] = {
    root = model.root,
    entries = model.entries or {},
    commits = model.commits or {},
    scope = model.scope,
    rows = rows,
  }
end

--- @param win integer
--- @param width integer
function M.configure_window(win, width)
  vim.api.nvim_win_set_width(win, width)
  vim.wo[win].winbar = '%!v:lua.require("unidiff.ui.list").winbar()'
  vim.wo[win].statuscolumn = '%!v:lua.require("unidiff.ui.list").statuscolumn()'
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  -- The diff beside it takes whatever is left, and keeps taking it when the
  -- window is resized.
  vim.wo[win].winfixwidth = true
end

--- What a row stands for, if it stands for anything.
--- @param buf integer
--- @param row integer 1-based
--- @return unidiff.ListTarget?
function M.target_at(buf, row)
  local state = M.state[buf]
  local r = state and state.rows[row]
  return r and r.target or nil
end

--- The entry a row stands for, if it stands for a file.
--- @param buf integer
--- @param row integer 1-based
--- @return unidiff.StatusEntry?
function M.entry_at(buf, row)
  local target = M.target_at(buf, row)
  if not target or target.kind ~= 'file' then
    return nil
  end
  return M.state[buf].entries[target.index]
end

--- Where a target is shown. The reverse of `target_at`, for moving the cursor
--- to something chosen from outside the list.
--- @param buf integer
--- @param target unidiff.ListTarget?
--- @return integer? row 1-based
function M.row_of(buf, target)
  local state = M.state[buf]
  if not state or not target then
    return nil
  end
  for row, r in ipairs(state.rows) do
    if r.target and r.target.kind == target.kind and r.target.index == target.index then
      return row
    end
  end
  return nil
end

--- Whether two targets name the same thing. They are compared by value because
--- each lookup builds a fresh table.
--- @param a unidiff.ListTarget?
--- @param b unidiff.ListTarget?
--- @return boolean
function M.same_target(a, b)
  if not a or not b then
    return a == nil and b == nil
  end
  return a.kind == b.kind and a.index == b.index
end

return M
