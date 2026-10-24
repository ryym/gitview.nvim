--- The file list: what it looks like, and which entry each row stands for.
---
--- As in a diff buffer, the text is the thing itself and the markers around it
--- are drawn rather than written. Here that means the buffer holds paths and
--- nothing else, so yanking a line gives a path that can be pasted somewhere
--- useful, while the two status letters are painted by `'statuscolumn'`.
local status = require('gitview.status')
local tree = require('gitview.tree')
local util = require('gitview.util')

local M = {}

--- @class gitview.ListScope a range whose files are listed: what the commits
--- pane is looking into, in place of the commits themselves, or what the files
--- pane is reviewing, in place of the uncommitted files
--- @field range gitview.Range the two revisions being compared
--- @field label string what to call it
--- @field at string? sha of the commit to put the cursor back on when backing
---        out, or `WORKTREE` for the working-tree row; nil for a review, which
---        backs out in the files pane
--- @field first string? sha of the commit at the older end, the one the range
---        starts at the parent of; nil when the range starts at a commit as it
---        stands, as a review of the working tree alone does
--- @field changes gitview.Change[] what the range changed

--- @class gitview.ListReview what the files pane is reviewing
--- @field scope gitview.ListScope
--- @field note string? what the winbar says about the range beyond what it
---        compares

--- @class gitview.ListModel what one pane of the sidebar is showing
--- @field pane 'files'|'commits' which of the two it is
--- @field root string repository root
--- @field entries gitview.StatusEntry[]? the files pane
--- @field review gitview.ListReview? the files pane, reviewing a range in place
---        of listing the entries
--- @field notice string? the files pane, shown in place of the entries while
---        there are none to show yet
--- @field layer gitview.Layer? the files pane, which changes the entries are
---        those with; both by default
--- @field commits gitview.Commit[]? the commits pane
--- @field worktree boolean? the commits pane, with a row for the working tree
---        above the commits
--- @field scope gitview.ListScope? the commits pane, looking into a range
--- @field stale boolean? the commits pane, holding a list `git log` no longer
---        agrees with; see `ui.session`
--- @field tree boolean? files laid out as a tree of directories rather than
---        one path after another

--- @class gitview.ListTarget what a row stands for
--- @field kind 'file'|'commit'|'worktree'|'commit_file'|'dir'|'commit_dir'
--- @field index integer into the entries, the commits, or the scope's changes.
---        Always 1 for the working tree, which there is only one of. For a
---        directory, the first file in it, which is also the next file below
---        its row
--- @field path string? the directory, without a trailing slash; `''` for the
---        root. A directory and the first file in it share an index, and so
---        may a directory and the one it is in
--- @field review true? a file or directory of the range under review, in the
---        files pane, rather than of the range looked into. The two can be the
---        same range, and are still two lists

--- @class gitview.ListSpan a stretch of a row drawn differently from its text
--- @field from integer 0-based byte column
--- @field to integer end-exclusive
--- @field conceal boolean? hidden from view, though still in the text
--- @field group string? highlight group the stretch is drawn in

--- @class gitview.ListRow
--- @field text string the buffer line, which is the thing itself
--- @field gutter string? what `'statuscolumn'` draws, highlight groups included
--- @field target gitview.ListTarget? absent on a row standing for nothing
--- @field spans gitview.ListSpan[]? drawn over the text as extmarks
--- @field subject integer? 0-based byte column where what the row names begins,
---        past any sha in front of it; colored while the diff shows the row.
---        Absent on a row standing for nothing, and on a directory, which the
---        diff has nothing to show for
--- @field indent integer? how many levels of a tree the row is nested in, each
---        drawn in front of the text as a guide
--- @field lead [string, string?][]? drawn after the indent, in front of the
---        name, as `virt_text` chunks: a directory's mark, or in a tree a file's
---        status letters

--- Shown instead of the list when there is nothing uncommitted. It is a row of
--- the buffer, so it has no entry and no status letters.
M.EMPTY_NOTICE = 'no uncommitted changes'

--- What to show instead of the list when no file has a change in `layer`.
--- @param layer gitview.Layer?
--- @return string
function M.empty_notice(layer)
  if layer == 'staged' or layer == 'unstaged' then
    return 'nothing ' .. layer
  end
  return M.EMPTY_NOTICE
end

--- Shown instead of the list until the uncommitted changes have been read.
M.LOADING_NOTICE = 'reading the status...'

--- Shown instead of the list when the uncommitted changes could not be read.
M.UNREADABLE_NOTICE = 'could not read the status'

--- Shown in the commits pane of a repository that has no commit yet.
M.NO_COMMITS_NOTICE = 'no commits yet'

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

--- Shown in place of the files of a review that has none. A review ending at
--- the working tree can be started before anything is edited, and its files
--- come in as they are.
M.EMPTY_REVIEW_NOTICE = 'nothing changed in the range'

--- Two status letters and a space. A row with no entry keeps the width so the
--- paths stay in one column.
local BLANK_GUTTER = '   '

--- What one level of a tree is drawn as: a guide, as indent-blankline draws one,
--- within the two columns a level takes anyway. Lines joining a directory to
--- each child (`├`, `└`) would need more width than a narrow sidebar has.
---
--- Drawn rather than taken from indent-blankline itself, which reads the
--- whitespace at the start of each line: a row here has none, since the indent
--- is virtual text and the text is the path alone.
local INDENT_GUIDE = '│ '

--- What a directory's row starts with. Every directory is open while there is
--- no way to close one, and the mark is there so a directory stands apart from
--- its files by more than a trailing slash.
---
--- `▼` is East Asian Ambiguous: two columns wide where 'ambiwidth' is double,
--- which is fine as long as the terminal agrees. The unambiguous `▾` is drawn
--- too small in many fonts to be read at a glance.
local DIR_MARK = '▼ '

--- What the root of a tree is called. It is a path like every other row, so a
--- yanked row still names something.
local ROOT_TEXT = './'

--- What a directory is called: its row's text, which is also how a message
--- names it.
--- @param path string without a trailing slash; `''` for the root
--- @return string
function M.dir_label(path)
  return path == '' and ROOT_TEXT or path .. '/'
end

--- The files of a list laid out as a tree.
---
--- A row's text stays the whole path, so yanking one still gives something
--- pasteable: the parent directory's part is concealed and the depth drawn in
--- front as an indent. A rename is placed where its new path is. When both
--- sides are in that directory, both drop the directory's part, which reads
--- `old.lua -> new.lua`; otherwise the whole label is shown, since it says
--- where the file came from.
---
--- The status letters move from the gutter to the front of the name. At the
--- left edge they would sit further from the name the deeper the file is.
---
--- @param files {path:string, old:string?, row:gitview.ListRow, letters:[string, string][]}[]
---        in byte order of `path`; see `gitview.tree`. `old` is the other side of
---        a rename, `row` what the flat list would show, and `letters` the status
---        letters it shows in its gutter
--- @param dir_kind 'dir'|'commit_dir'
--- @param review true? the files are those of a review
--- @return gitview.ListRow[]
local function tree_rows(files, dir_kind, review)
  local paths = vim.tbl_map(function(f)
    return f.path
  end, files)
  local nodes = tree.build(paths)

  -- A directory's target is the first file in it, which is the next file below.
  local next_file = {}
  local seen
  for i = #nodes, 1, -1 do
    seen = nodes[i].index or seen
    next_file[i] = seen
  end

  local rows = {}
  for i, n in ipairs(nodes) do
    local row --- @type gitview.ListRow
    if n.index then
      local f = files[n.index]
      row = f.row
      local spans = {}
      local parent = f.path:sub(1, n.col)
      if not f.old then
        spans[1] = { from = 0, to = n.col, conceal = true }
        row.subject = n.col
      elseif f.old:sub(1, n.col) == parent and not f.old:find('/', n.col + 1, true) then
        local new_at = #f.old + #' -> '
        spans[1] = { from = 0, to = n.col, conceal = true }
        spans[2] = { from = new_at, to = new_at + n.col, conceal = true }
        row.subject = n.col
      end
      row.spans = vim.tbl_filter(function(sp)
        return sp.to > sp.from
      end, spans)
      row.gutter = nil
      row.lead = vim.list_extend(vim.deepcopy(f.letters), { { ' ' } })
    else
      local text = M.dir_label(n.dir)
      local spans = { { from = n.col, to = #text, group = 'GitViewDirectory' } }
      if n.col > 0 then
        table.insert(spans, 1, { from = 0, to = n.col, conceal = true })
      end
      row = {
        text = text,
        target = { kind = dir_kind, index = next_file[i], path = n.dir, review = review },
        spans = spans,
        lead = { { DIR_MARK, 'GitViewDirectory' } },
      }
    end
    row.indent = n.depth
    rows[i] = row
  end
  return rows
end

--- An entry's status letters, each with its highlight group.
--- @param e gitview.StatusEntry
--- @return [string, string][]
local function letters_of(e)
  if status.is_untracked(e) then
    return { { '??', 'GitViewStatusUntracked' } }
  end
  return { { e.index_status, 'GitViewStatusStaged' }, { e.worktree_status, 'GitViewStatusUnstaged' } }
end

--- The gutter is computed when the row is built rather than when the screen
--- line is drawn, because rows no longer all stand for the same kind of thing:
--- an entry has two status letters, a commit has none, and `'statuscolumn'`
--- would otherwise have to know about every kind.
---
--- Padded to the width of two letters and a space, so the paths stay in one
--- column whichever kind of file the row is.
--- @param letters [string, string][]
--- @return string
local function gutter_of(letters)
  local out, width = {}, 0
  for _, l in ipairs(letters) do
    out[#out + 1] = ('%%#%s#%s'):format(l[2], l[1])
    width = width + #l[1]
  end
  return table.concat(out) .. (' '):rep(#BLANK_GUTTER - width)
end

--- The files a range changed, shown in place of what the pane otherwise lists:
--- the commits, for a range looked into, or the uncommitted files, for one
--- under review.
---
--- A range's changes and the uncommitted entries are different shapes, so they
--- are never mixed into one buffer: the range replaces what the pane holds.
--- Which range that is, is named by the pane's `'winbar'`, so no row of the
--- buffer has to stand for it.
---
--- @param scope gitview.ListScope
--- @param as_tree boolean?
--- @param review true? the range is under review
--- @return gitview.ListRow[]
local function scope_rows(scope, as_tree, review)
  if #scope.changes == 0 then
    return { { text = review and M.EMPTY_REVIEW_NOTICE or M.EMPTY_COMMIT_NOTICE } }
  end
  local rows, files = {}, {}
  for i, c in ipairs(scope.changes) do
    -- One letter, in the color the list already uses for a settled change.
    local letters = { { c.status, 'GitViewStatusStaged' } }
    rows[i] = {
      text = status.change_label(c),
      gutter = gutter_of(letters),
      target = { kind = 'commit_file', index = i, review = review },
      subject = 0,
    }
    local renamed = (c.status == 'R' or c.status == 'C') and c.old_path or nil
    files[i] = { path = c.path, old = renamed, row = rows[i], letters = letters }
  end
  return as_tree and tree_rows(files, 'commit_dir', review) or rows
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
    if model.review then
      return scope_rows(model.review.scope, model.tree, true)
    end
    if model.notice then
      return { { text = model.notice } }
    end
    local entries = model.entries or {}
    if #entries == 0 then
      return { { text = M.empty_notice(model.layer) } }
    end
    local rows, files = {}, {}
    for i, e in ipairs(entries) do
      local letters = letters_of(e)
      rows[i] = {
        text = status.label(e),
        gutter = gutter_of(letters),
        target = { kind = 'file', index = i },
        subject = 0,
      }
      local renamed = e.head_path and e.head_path ~= e.path and e.head_path or nil
      files[i] = { path = e.path, old = renamed, row = rows[i], letters = letters }
    end
    return model.tree and tree_rows(files, 'dir') or rows
  end

  if model.scope then
    return scope_rows(model.scope, model.tree)
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
    local text = ('%s %s'):format(zeros, WORKTREE_SUBJECT)
    -- Faded, since it is not a commit: it stands for what is not recorded yet.
    local spans = sha_spans(zeros)
    spans[#spans + 1] = { from = 0, to = #text, group = 'GitViewCommitWorktree' }
    rows[1] = {
      text = text,
      target = { kind = 'worktree', index = 1 },
      spans = spans,
      subject = #zeros + 1,
    }
  end
  for i, c in ipairs(commits) do
    rows[#rows + 1] = {
      text = ('%s %s'):format(c.sha, c.subject),
      target = { kind = 'commit', index = i },
      spans = vim.list_extend(sha_spans(c.sha), {
        { from = 0, to = #c.sha, group = 'GitViewCommitSha' },
      }),
      subject = #c.sha + 1,
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
  set('GitViewCommitWorktree', { link = 'Comment' })
  set('GitViewDirectory', { link = 'Directory' })
  -- What indent-blankline's own guides default to, so the two look alike.
  set('GitViewIndent', { link = 'Whitespace' })
  -- As Neovim's own git syntax colors a hash, so a sha reads the same here as
  -- in `git show` or a rebase todo.
  set('GitViewCommitSha', { link = 'Identifier' })
  -- What is pushed has settled. What is not yet stands out against it without a
  -- color of its own, which would make an ordinary state look like a warning.
  set('GitViewCommitShaPushed', { link = 'Comment' })
  set('GitViewUpstream', { link = 'Comment' })
  -- Dimmer than the name it carries, and as dim as the indent guides, so the
  -- line sits back like the borders between windows rather than outweighing
  -- them.
  set('GitViewUpstreamRule', { link = 'Whitespace' })
  set('GitViewListCursor', { link = 'Title' })
  -- A range is a selection, and is colored as one, though no Visual mode is
  -- involved.
  set('GitViewRange', { link = 'Visual' })
end)

M.setup_highlights = highlights.apply

--- Sessions by the buffer holding their list, so that `'statuscolumn'` can find
--- what a screen line belongs to. Filled in by `ui.session`.
---
--- Kept off `M` on purpose: the window options call into this module as
--- `v:lua.require(...).fn()`, which converts `M` into a Vim value on every call.
--- @type table<integer, gitview.ListModel|{rows:gitview.ListRow[], range:integer?}>
local states = {}

--- What `buf` is showing, if it is a list.
--- @param buf integer
--- @return (gitview.ListModel|{rows:gitview.ListRow[], range:integer?})?
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
  -- Commit rows have nothing to put there, and the sidebar is too narrow to
  -- give the width away: the subjects take it instead. A commit's files keep
  -- the gutter for their status letters.
  if state.pane == 'commits' and not state.scope then
    return ''
  end
  -- A tree draws the status letters in front of each name instead.
  if state.tree then
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
  if state.review then
    -- The range has no row of its own, as one looked into has none.
    text = ' review ' .. state.review.scope.label
    if state.review.note then
      text = ('%s   %s'):format(text, state.review.note)
    end
  elseif state.pane == 'files' then
    text = ' ' .. vim.fs.basename(state.root)
    -- Zero files would be a claim about a list that has not been read.
    if not state.notice then
      -- A layer alone is named by what it counts, since the list leaving files
      -- out unannounced would be a trap.
      local layer = state.layer or 'both'
      local count = layer == 'both' and util.counted(#state.entries, 'file')
        or ('%d %s'):format(#state.entries, layer)
      text = ('%s   %s'):format(text, count)
    end
  elseif state.scope then
    -- What is being looked into has no row of its own, so this is the only place
    -- it is named.
    text = ' ' .. state.scope.label
  else
    text = ' ' .. util.counted(#state.commits, 'commit')
    if state.range then
      -- Also the only sign of a mark the cursor is on: a range of one row looks
      -- like no range at all.
      text = ('%s   range of %d'):format(text, state.range)
    end
    if state.stale then
      -- The list is being held open for a commit the log no longer names, so
      -- what it shows is older than the repository.
      text = text .. '   (history changed)'
    end
  end
  return util.escape_statusline(text)
end

local ns = vim.api.nvim_create_namespace('gitview.ui.list')
local cursor_ns = vim.api.nvim_create_namespace('gitview.ui.list.cursor')
local range_ns = vim.api.nvim_create_namespace('gitview.ui.list.range')
local upstream_ns = vim.api.nvim_create_namespace('gitview.ui.list.upstream')

--- Above the spans a row is drawn with, so the row the diff shows stands out
--- even where the whole row is already colored, as the working-tree row is.
local CURSOR_PRIORITY = vim.hl.priorities.user + 1

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
    local lead = {}
    for _ = 1, r.indent or 0 do
      lead[#lead + 1] = { INDENT_GUIDE, 'GitViewIndent' }
    end
    vim.list_extend(lead, r.lead or {})
    if #lead > 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = lead,
        virt_text_pos = 'inline',
      })
    end
    for _, span in ipairs(r.spans or {}) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, span.from, {
        end_col = span.to,
        conceal = span.conceal and '' or nil,
        hl_group = span.group,
        priority = vim.hl.priorities.user,
      })
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  states[buf] = {
    pane = model.pane,
    root = model.root,
    entries = model.entries or {},
    review = model.review,
    notice = model.notice,
    layer = model.layer,
    commits = model.commits or {},
    scope = model.scope,
    stale = model.stale,
    tree = model.tree,
    rows = rows,
  }
end

--- Color what the row the diff is showing names, or nothing.
---
--- `'cursorline'` alone cannot say which of the two panes the diff follows: both
--- panes have a cursor line, drawn alike. Only the pane the diff follows is
--- given this, so it is also what tells the panes apart, and it stays while the
--- focus is in the diff, which is when it is needed most.
---
--- Kept apart from `draw`, since the cursor moves far more often than the list
--- changes.
--- @param buf integer
--- @param row integer? 1-based; nil clears
function M.paint_cursor(buf, row)
  vim.api.nvim_buf_clear_namespace(buf, cursor_ns, 0, -1)
  local state = states[buf]
  local r = row and state and state.rows[row]
  if not r or not r.subject then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, cursor_ns, row - 1, r.subject, {
    end_col = #r.text,
    hl_group = 'GitViewListCursor',
    priority = CURSOR_PRIORITY,
  })
end

--- Color the rows of a range, or none.
---
--- A range mark with `hl_eol` rather than `line_hl_group`, which is drawn
--- outside the priority order and would cover the colors of the text with those
--- of the range. Below the spans, so a sha keeps its color inside a range.
--- @param buf integer
--- @param first integer? 1-based; nil clears
--- @param last integer? 1-based, inclusive
function M.paint_range(buf, first, last)
  vim.api.nvim_buf_clear_namespace(buf, range_ns, 0, -1)
  local state = states[buf]
  if state then
    state.range = first and last - first + 1 or nil
  end
  if not first then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, range_ns, first - 1, 0, {
    end_row = last,
    end_col = 0,
    hl_group = 'GitViewRange',
    hl_eol = true,
    priority = vim.hl.priorities.user - 1,
  })
end

--- Show which commits are pushed and where the upstream is, or nothing.
---
--- A pushed sha is faded over the color `draw` gave it. Without an upstream
--- nothing is known to be pushed, so every sha keeps the color it has everywhere
--- else, as an unpushed one does; a branch that tracks nothing has been pushed
--- nowhere anyway.
---
--- Kept apart from `draw`, since the upstream moves on a fetch or a push, which
--- changes nothing else the list shows.
--- @param buf integer
--- @param upstream gitview.Upstream? nil clears
--- @param unpushed table<string, true>? the full shas of the commits `upstream`
---        does not have
function M.paint_upstream(buf, upstream, unpushed)
  vim.api.nvim_buf_clear_namespace(buf, upstream_ns, 0, -1)
  local state = states[buf]
  if not upstream or not unpushed or not state then
    return
  end
  for i, r in ipairs(state.rows) do
    local c = r.target and r.target.kind == 'commit' and state.commits[r.target.index]
    if c then
      if not unpushed[c.full_sha] then
        vim.api.nvim_buf_set_extmark(buf, upstream_ns, i - 1, 0, {
          end_col = #c.sha,
          hl_group = 'GitViewCommitShaPushed',
          priority = vim.hl.priorities.user + 1,
        })
      end
      -- Where the upstream is rather than below the last unpushed row: a merge
      -- from it can leave pushed commits between unpushed ones. An upstream the
      -- list does not reach, being older or diverged, is not shown at all.
      --
      -- Hung below the row above rather than above this one: lines above the
      -- first line of a buffer are only shown once the window is scrolled up
      -- onto them. The first row has none above it, and the line is left out
      -- until a working-tree row is drawn there.
      if c.full_sha == upstream.sha and i > 1 then
        local lead = '── '
        local name = upstream.name .. ' '
        -- As wide as any window could be, since the line is cut off at its edge.
        local fill = math.max(vim.o.columns - vim.fn.strdisplaywidth(lead .. name), 0)
        vim.api.nvim_buf_set_extmark(buf, upstream_ns, i - 2, 0, {
          virt_lines = {
            {
              { lead, 'GitViewUpstreamRule' },
              { name, 'GitViewUpstream' },
              { ('─'):rep(fill), 'GitViewUpstreamRule' },
            },
          },
        })
      end
    end
  end
end

--- @param win integer
function M.configure_window(win)
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
    -- `c` covers the line 'incsearch' moves the cursor to while a search is typed.
    conceallevel = 2,
    concealcursor = 'nvc',
    -- The session sets the width itself, so a window opened or closed beside
    -- it leaves the width to the diff.
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
    if M.same_target(r.target, target) then
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
  return a.kind == b.kind and a.index == b.index and a.path == b.path and a.review == b.review
end

return M
