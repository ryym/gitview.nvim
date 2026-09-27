--- The file list: what it looks like, and which entry each row stands for.
---
--- As in a diff buffer, the text is the thing itself and the markers around it
--- are drawn rather than written. Here that means the buffer holds paths and
--- nothing else, so yanking a line gives a path that can be pasted somewhere
--- useful, while the two status letters are painted by `'statuscolumn'`.
local status = require('unidiff.status')
local util = require('unidiff.util')

local M = {}

--- @class unidiff.ListScope what the commits pane is looking into, in place of
--- the commits themselves
--- @field range unidiff.Range the two revisions being compared
--- @field label string what to call it
--- @field at string sha of the commit to put the cursor back on when backing out
--- @field changes unidiff.Change[] what the range changed

--- @class unidiff.ListModel what one pane of the sidebar is showing
--- @field pane 'files'|'commits' which of the two it is
--- @field root string repository root
--- @field entries unidiff.StatusEntry[]? the files pane
--- @field commits unidiff.Commit[]? the commits pane
--- @field mark string? sha of the marked commit, the far end of a range
--- @field scope unidiff.ListScope? the commits pane, looking into a range
--- @field stale boolean? the commits pane, holding a list `git log` no longer
---        agrees with; see `ui.session`

--- @class unidiff.ListTarget what a row stands for
--- @field kind 'file'|'commit'|'commit_file'
--- @field index integer into the entries, the commits, or the scope's changes

--- @class unidiff.ListRow
--- @field text string the buffer line, which is the thing itself
--- @field gutter string? what `'statuscolumn'` draws, highlight groups included
--- @field target unidiff.ListTarget? absent on a row standing for nothing

--- Shown instead of the list when there is nothing uncommitted. It is a row of
--- the buffer, so it has no entry and no status letters.
M.EMPTY_NOTICE = 'no uncommitted changes'

--- Shown in the commits pane of a repository that has no commit yet.
M.NO_COMMITS_NOTICE = 'no commits yet'

--- Drawn in the gutter of the marked commit. A commit row has no status letters
--- of its own, so the mark has the width to itself.
local MARK_GUTTER = '%#UnidiffStatusMark#>  '

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
  if status.is_untracked(e) then
    return '%#UnidiffStatusUntracked#?? '
  end
  return ('%%#UnidiffStatusStaged#%s%%#UnidiffStatusUnstaged#%s '):format(
    e.index_status,
    e.worktree_status
  )
end

--- The files one commit changed, shown in the commits pane in place of the
--- commits themselves.
---
--- A commit's changes and the uncommitted entries are different shapes, so they
--- are never mixed into one buffer: looking into a commit replaces what the
--- pane holds. Which commit that is, is named by the pane's `'winbar'`, so no
--- row of the buffer has to stand for it.
---
--- @param scope unidiff.ListScope
--- @return unidiff.ListRow[]
local function scope_rows(scope)
  if #scope.changes == 0 then
    return { { text = M.EMPTY_COMMIT_NOTICE } }
  end
  local rows = {}
  for i, c in ipairs(scope.changes) do
    rows[i] = {
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
  if model.pane == 'files' then
    local entries = model.entries or {}
    if #entries == 0 then
      return { { text = M.EMPTY_NOTICE } }
    end
    local rows = {}
    for i, e in ipairs(entries) do
      rows[i] = {
        text = status.label(e),
        gutter = gutter_of(e),
        target = { kind = 'file', index = i },
      }
    end
    return rows
  end

  if model.scope then
    return scope_rows(model.scope)
  end
  local commits = model.commits or {}
  if #commits == 0 then
    return { { text = M.NO_COMMITS_NOTICE } }
  end
  local rows = {}
  for i, c in ipairs(commits) do
    rows[i] = {
      text = ('%s %s'):format(c.sha, c.subject),
      gutter = c.sha == model.mark and MARK_GUTTER or nil,
      target = { kind = 'commit', index = i },
    }
  end
  return rows
end

--- Status letters are foreground colors, unlike the diff backgrounds, so they
--- are taken from the groups Neovim already defines for exactly this: `Added`,
--- `Changed` and `Comment`. Defining any of them yourself takes precedence.
local highlights = util.highlights('unidiff.ui.highlights', function(set)
  set('UnidiffStatusStaged', { link = 'Added' })
  set('UnidiffStatusUnstaged', { link = 'Changed' })
  set('UnidiffStatusUntracked', { link = 'Comment' })
  set('UnidiffStatusHeader', { link = 'Title' })
  set('UnidiffStatusMark', { link = 'Special' })
end)

M.setup_highlights = highlights.apply

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

--- What the pane is showing. The repository is named by the files pane alone,
--- since both panes are the same repository and the name would only be read
--- once.
--- @return string
function M.winbar()
  local win = vim.g.statusline_winid
  local state = M.state[vim.api.nvim_win_get_buf(win)]
  if not state then
    return ''
  end
  local text
  if state.pane == 'files' then
    text = (' %s   %s'):format(vim.fs.basename(state.root), util.counted(#state.entries, 'file'))
  elseif state.scope then
    -- What is being looked into has no row of its own, so this is the only place
    -- it is named.
    text = ' ' .. state.scope.label
  else
    text = ' ' .. util.counted(#state.commits, 'commit')
    if state.stale then
      -- The list is being held open for a commit the log no longer names, so
      -- what it shows is older than the repository.
      text = text .. '   (history changed)'
    end
  end
  return '%#UnidiffStatusHeader#' .. util.escape_statusline(text)
end

--- @return integer bufnr
function M.create_buffer()
  M.setup_highlights()
  return util.scratch_buffer('unidiffstatus', M.state)
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
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  M.state[buf] = {
    pane = model.pane,
    root = model.root,
    entries = model.entries or {},
    commits = model.commits or {},
    scope = model.scope,
    stale = model.stale,
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
