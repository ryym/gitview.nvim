--- The file list: what it looks like, and which entry each row stands for.
---
--- As in a diff buffer, the text is the thing itself and the markers around it
--- are drawn rather than written. Here that means the buffer holds paths and
--- nothing else, so yanking a line gives a path that can be pasted somewhere
--- useful, while the two status letters are painted by `'statuscolumn'`.
local status = require('gitview.status')
local util = require('gitview.util')

local M = {}

--- @class gitview.ListScope what the commits pane is looking into, in place of
--- the commits themselves
--- @field range gitview.Range the two revisions being compared
--- @field label string what to call it
--- @field at string sha of the commit to put the cursor back on when backing out,
---        or `WORKTREE` for the working-tree row
--- @field changes gitview.Change[] what the range changed

--- @class gitview.ListModel what one pane of the sidebar is showing
--- @field pane 'files'|'commits' which of the two it is
--- @field root string repository root
--- @field entries gitview.StatusEntry[]? the files pane
--- @field notice string? the files pane, shown in place of the entries while
---        there are none to show yet
--- @field commits gitview.Commit[]? the commits pane
--- @field worktree boolean? the commits pane, with a row for the working tree
---        above the commits
--- @field mark string? sha of the marked commit, the far end of a range, or
---        `WORKTREE` when that is the working-tree row
--- @field scope gitview.ListScope? the commits pane, looking into a range
--- @field stale boolean? the commits pane, holding a list `git log` no longer
---        agrees with; see `ui.session`

--- @class gitview.ListTarget what a row stands for
--- @field kind 'file'|'commit'|'worktree'|'commit_file'
--- @field index integer into the entries, the commits, or the scope's changes.
---        Always 1 for the working tree, which there is only one of

--- @class gitview.ListSpan a stretch of a row drawn differently from its text
--- @field from integer 0-based byte column
--- @field to integer end-exclusive
--- @field conceal boolean? hidden from view, though still in the text

--- @class gitview.ListRow
--- @field text string the buffer line, which is the thing itself
--- @field gutter string? what `'statuscolumn'` draws, highlight groups included
--- @field target gitview.ListTarget? absent on a row standing for nothing
--- @field spans gitview.ListSpan[]? drawn over the text as extmarks

--- Shown instead of the list when there is nothing uncommitted. It is a row of
--- the buffer, so it has no entry and no status letters.
M.EMPTY_NOTICE = 'no uncommitted changes'

--- Shown instead of the list until the uncommitted changes have been read.
M.LOADING_NOTICE = 'reading the status...'

--- Shown instead of the list when the uncommitted changes could not be read.
M.UNREADABLE_NOTICE = 'could not read the status'

--- Shown in the commits pane of a repository that has no commit yet.
M.NO_COMMITS_NOTICE = 'no commits yet'

--- Drawn in the gutter of the marked commit. A commit row has no status letters
--- of its own, so the mark has the width to itself.
local MARK_GUTTER = '%#GitViewStatusMark#>  '

--- What `mark` and `ListScope.at` hold for the working-tree row, which has no
--- sha. It cannot be mistaken for one, since a sha is hexadecimal.
M.WORKTREE = 'worktree'

--- The working-tree row's subject. The row stands for the working tree as one
--- end of a range, the way a commit row stands for a commit.
local WORKTREE_SUBJECT = 'uncommitted changes'

--- How much of a sha a commit row shows. The rest is concealed rather than left
--- out: the list only has to tell neighbouring commits apart, which a few
--- characters do, while a yanked row still needs a sha git can resolve.
local SHA_SHOWN = 4

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
--- @param e gitview.StatusEntry
--- @return string
local function gutter_of(e)
  if status.is_untracked(e) then
    return '%#GitViewStatusUntracked#?? '
  end
  return ('%%#GitViewStatusStaged#%s%%#GitViewStatusUnstaged#%s '):format(
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
--- @param scope gitview.ListScope
--- @return gitview.ListRow[]
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
      gutter = ('%%#GitViewStatusStaged#%s  '):format(c.status),
      target = { kind = 'commit_file', index = i },
    }
  end
  return rows
end

--- What hides the tail of a sha at the start of a row. `%h` is never shorter
--- than four, but a shorter one would simply be shown whole.
--- @param sha string
--- @return gitview.ListSpan[]
local function sha_spans(sha)
  if #sha <= SHA_SHOWN then
    return {}
  end
  return { { from = SHA_SHOWN, to = #sha, conceal = true } }
end

--- @param model gitview.ListModel
--- @return gitview.ListRow[]
function M.content(model)
  if model.pane == 'files' then
    if model.notice then
      return { { text = model.notice } }
    end
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
  if model.worktree then
    -- Zeros as wide as the shas below, the way git writes the sha of nothing,
    -- so that the subjects stay in one column.
    local zeros = ('0'):rep(#commits[1].sha)
    rows[1] = {
      text = ('%s %s'):format(zeros, WORKTREE_SUBJECT),
      gutter = model.mark == M.WORKTREE and MARK_GUTTER or nil,
      target = { kind = 'worktree', index = 1 },
      spans = sha_spans(zeros),
    }
  end
  for i, c in ipairs(commits) do
    rows[#rows + 1] = {
      text = ('%s %s'):format(c.sha, c.subject),
      gutter = c.sha == model.mark and MARK_GUTTER or nil,
      target = { kind = 'commit', index = i },
      spans = sha_spans(c.sha),
    }
  end
  return rows
end

--- Status letters are foreground colors, unlike the diff backgrounds, so they
--- are taken from the groups Neovim already defines for exactly this: `Added`,
--- `Changed` and `Comment`. Defining any of them yourself takes precedence.
local highlights = util.highlights('gitview.ui.highlights', function(set)
  set('GitViewStatusStaged', { link = 'Added' })
  set('GitViewStatusUnstaged', { link = 'Changed' })
  set('GitViewStatusUntracked', { link = 'Comment' })
  set('GitViewStatusHeader', { link = 'Title' })
  set('GitViewStatusMark', { link = 'Special' })
end)

M.setup_highlights = highlights.apply

--- Sessions by the buffer holding their list, so that `'statuscolumn'` can find
--- what a screen line belongs to. Filled in by `ui.session`.
---
--- Kept off `M` on purpose: the window options call into this module as
--- `v:lua.require(...).fn()`, which converts `M` into a Vim value on every call.
--- @type table<integer, gitview.ListModel|{rows:gitview.ListRow[]}>
local states = {}

--- What `buf` is showing, if it is a list.
--- @param buf integer
--- @return (gitview.ListModel|{rows:gitview.ListRow[]})?
function M.state_of(buf)
  return states[buf]
end

--- @return string
function M.statuscolumn()
  local win = vim.g.statusline_winid
  local state = states[vim.api.nvim_win_get_buf(win)]
  -- A window that inherited 'statuscolumn' from a list window is showing another
  -- buffer, which has no gutter: drawing blanks would leave it an empty column.
  if not state then
    return ''
  end
  if vim.v.virtnum ~= 0 then
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
  local state = states[vim.api.nvim_win_get_buf(win)]
  if not state then
    return ''
  end
  local text
  if state.pane == 'files' then
    text = ' ' .. vim.fs.basename(state.root)
    -- Zero files would be a claim about a list that has not been read.
    if not state.notice then
      text = ('%s   %s'):format(text, util.counted(#state.entries, 'file'))
    end
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
  return '%#GitViewStatusHeader#' .. util.escape_statusline(text)
end

local ns = vim.api.nvim_create_namespace('gitview.ui.list')

--- @return integer bufnr
function M.create_buffer()
  M.setup_highlights()
  return util.scratch_buffer('gitview-list', states)
end

--- @param buf integer from `create_buffer`
--- @param model gitview.ListModel
function M.draw(buf, model)
  local rows = M.content(model)
  local texts = {}
  for i, r in ipairs(rows) do
    texts[i] = r.text
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, r in ipairs(rows) do
    for _, span in ipairs(r.spans or {}) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, span.from, {
        end_col = span.to,
        conceal = span.conceal and '' or nil,
      })
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  states[buf] = {
    pane = model.pane,
    root = model.root,
    entries = model.entries or {},
    notice = model.notice,
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
  util.configure_window_options(win, {
    winbar = '%!v:lua.require("gitview.ui.list").winbar()',
    statuscolumn = '%!v:lua.require("gitview.ui.list").statuscolumn()',
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    wrap = false,
    cursorline = true,
    -- What a span conceals stays hidden on the cursor line too, or the row under
    -- the cursor would be the one whose subject is out of line with the rest.
    conceallevel = 2,
    concealcursor = 'nv',
    -- The diff beside it takes whatever is left, and keeps taking it when the
    -- window is resized.
    winfixwidth = true,
  })
end

--- What a row stands for, if it stands for anything.
--- @param buf integer
--- @param row integer 1-based
--- @return gitview.ListTarget?
function M.target_at(buf, row)
  local state = states[buf]
  local r = state and state.rows[row]
  return r and r.target or nil
end

--- The entry a row stands for, if it stands for a file.
--- @param buf integer
--- @param row integer 1-based
--- @return gitview.StatusEntry?
function M.entry_at(buf, row)
  local target = M.target_at(buf, row)
  if not target or target.kind ~= 'file' then
    return nil
  end
  return states[buf].entries[target.index]
end

--- Where a target is shown. The reverse of `target_at`, for moving the cursor
--- to something chosen from outside the list.
--- @param buf integer
--- @param target gitview.ListTarget?
--- @return integer? row 1-based
function M.row_of(buf, target)
  local state = states[buf]
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
--- @param a gitview.ListTarget?
--- @param b gitview.ListTarget?
--- @return boolean
function M.same_target(a, b)
  if not a or not b then
    return a == nil and b == nil
  end
  return a.kind == b.kind and a.index == b.index
end

return M
