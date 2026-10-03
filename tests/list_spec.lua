local list = require('gitview.ui.list')

local test, eq = _G.test, _G.eq

--- @param x string index status
--- @param y string worktree status
--- @param path string
--- @param head_path string?
--- @return gitview.StatusEntry
local function entry(x, y, path, head_path)
  return {
    path = path,
    head_path = head_path or path,
    index_status = x,
    worktree_status = y,
    binary = false,
  }
end

--- @param rows gitview.ListRow[]
--- @return string[]
local function texts(rows)
  return vim.tbl_map(function(r)
    return r.text
  end, rows)
end

--- @param sha string
--- @param subject string
--- @return gitview.Commit
local function commit(sha, subject)
  return { sha = sha, parents = { 'p' }, subject = subject, author = 'a', when = 'now' }
end

-- The buffer holds paths and nothing else, so that yanking a row gives
-- something pasteable. The status letters live in the 'statuscolumn'.
test('list: rows are paths, without their status letters', function()
  local rows = list.content({ pane = 'files', entries = { entry('M', ' ', 'a.txt'), entry('?', '?', 'new.txt') } })
  eq({ 'a.txt', 'new.txt' }, texts(rows))
end)

test('list: a rename names both sides', function()
  eq({ 'old.txt -> new.txt' }, texts(list.content({ pane = 'files', entries = { entry('R', ' ', 'new.txt', 'old.txt') } })))
end)

test('list: every row maps back to its entry', function()
  local rows = list.content({ pane = 'files', entries = { entry('M', ' ', 'a.txt'), entry(' ', 'M', 'b.txt') } })
  eq({ kind = 'file', index = 1 }, rows[1].target)
  eq({ kind = 'file', index = 2 }, rows[2].target)
end)

-- The notice is a buffer row like any other, but it stands for no file, so
-- nothing may resolve it to an entry.
test('list: an empty repository shows a notice that maps to nothing', function()
  local rows = list.content({ pane = 'files', entries = {} })
  eq({ list.EMPTY_NOTICE }, texts(rows))
  eq(nil, rows[1].target)
end)

-- A commit row states its own sha and subject, so yanking one gives something
-- that identifies the commit elsewhere.
-- The two lists are separate panes, so the files pane holds files and nothing
-- else however much history there is.
test('list: the files pane holds only the files', function()
  local rows = list.content({
    pane = 'files',
    entries = { entry('M', ' ', 'a.txt') },
    commits = { commit('abc1234', 'do a thing') },
  })
  eq({ 'a.txt' }, texts(rows))
end)

test('list: the commits pane holds one row per commit', function()
  local rows = list.content({
    pane = 'commits',
    entries = { entry('M', ' ', 'a.txt') },
    commits = { commit('abc1234', 'do a thing'), commit('def5678', 'another') },
  })
  eq({ 'abc1234 do a thing', 'def5678 another' }, texts(rows))
  eq({ kind = 'commit', index = 2 }, rows[2].target)
end)

-- A few characters tell neighbouring commits apart, but a yanked row has to
-- name a commit git can resolve, so the rest of the sha is hidden rather than
-- left out.
test('list: a commit row shows the start of its sha and keeps the rest', function()
  local buf = list.create_buffer()
  list.draw(buf, { pane = 'commits', root = '/tmp/repo', worktree = true, commits = { commit('abc1234', 'x') } })
  eq({ '0000000 uncommitted changes', 'abc1234 x' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local concealed = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    if m[4].conceal then
      concealed[#concealed + 1] = { m[2], m[3], m[4].end_col, m[4].conceal }
    end
  end
  eq({ { 0, 4, 7, '' }, { 1, 4, 7, '' } }, concealed)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('list: the working-tree row is faded as a whole', function()
  local rows = list.content({ pane = 'commits', worktree = true, commits = { commit('abc1234', 'x') } })
  eq({ from = 0, to = #rows[1].text, group = 'GitViewCommitWorktree' }, rows[1].spans[#rows[1].spans])
  for _, span in ipairs(rows[2].spans) do
    eq(nil, span.group)
  end
end)

--- The stretch of `row` the cursor paint covers, with its priority.
--- @param buf integer
--- @param row integer 1-based
--- @return {from:integer, to:integer, priority:integer}?
local function cursor_paint(buf, row)
  local ns = vim.api.nvim_create_namespace('gitview.ui.list.cursor')
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  local m = marks[1]
  return m and { from = m[3], to = m[4].end_col, priority = m[4].priority } or nil
end

-- What the row names is colored, not the sha in front of it, which is already
-- colored for what it says about the commit.
test('list: the cursor paint covers what the row names', function()
  local buf = list.create_buffer()
  list.draw(buf, { pane = 'commits', root = '/tmp/repo', worktree = true, commits = { commit('abc1234', 'x') } })
  list.paint_cursor(buf, 2)
  eq(8, cursor_paint(buf, 2).from)
  eq(9, cursor_paint(buf, 2).to)
  -- one row at a time
  list.paint_cursor(buf, 1)
  eq(nil, cursor_paint(buf, 2))
  -- above the fade of the working-tree row, or it would not show there
  local fade = vim.tbl_filter(function(m)
    return m[4].hl_group == 'GitViewCommitWorktree'
  end, vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true }))[1]
  assert(cursor_paint(buf, 1).priority > fade[4].priority, 'the cursor paint must win over the fade')
  list.paint_cursor(buf, nil)
  eq(nil, cursor_paint(buf, 1))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('list: a file row is painted whole, and a notice not at all', function()
  local buf = list.create_buffer()
  list.draw(buf, { pane = 'files', root = '/tmp/repo', entries = { entry('M', ' ', 'a.txt') } })
  list.paint_cursor(buf, 1)
  eq({ from = 0, to = 5 }, { from = cursor_paint(buf, 1).from, to = cursor_paint(buf, 1).to })
  list.draw(buf, { pane = 'files', root = '/tmp/repo', entries = {} })
  list.paint_cursor(buf, 1)
  eq(nil, cursor_paint(buf, 1))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- A repository with no commit has no log to show, and an empty pane would say
-- nothing about why.
test('list: a repository with no commits says so', function()
  local rows = list.content({ pane = 'commits', commits = {} })
  eq({ list.NO_COMMITS_NOTICE }, texts(rows))
  eq(nil, rows[1].target)
end)

-- A commit has no index and no working tree, so there are no two letters to
-- show; the width is kept so the rows still line up.
test('list: a commit row has no status letters', function()
  local rows = list.content({ commits = { commit('abc1234', 'x') } })
  eq(nil, rows[#rows].gutter)
end)

test('list: a target resolves back to the row showing it', function()
  local buf = list.create_buffer()
  list.draw(buf, { pane = 'commits', root = '/tmp/repo', commits = { commit('abc1234', 'x') } })
  eq(1, list.row_of(buf, { kind = 'commit', index = 1 }))
  eq(nil, list.row_of(buf, { kind = 'commit', index = 2 }))
  -- a target of another pane is not in this one
  eq(nil, list.row_of(buf, { kind = 'file', index = 1 }))
  eq({ kind = 'commit', index = 1 }, list.target_at(buf, 1))
  eq(nil, list.target_at(buf, 2))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

--- @param entries gitview.StatusEntry[]
--- @param lnum integer
--- @return string
local function gutter(entries, lnum)
  local buf = list.create_buffer()
  list.draw(buf, { pane = 'files', root = '/tmp/repo', entries = entries })
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    row = 0,
    col = 0,
    width = 20,
    height = 5,
  })
  vim.g.statusline_winid = win
  vim.v.lnum = lnum
  local out = list.statuscolumn()
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  return out
end

test('list: the gutter shows one letter per side', function()
  local entries = { entry('M', 'M', 'a.txt'), entry(' ', 'D', 'b.txt') }
  eq('%#GitViewStatusStaged#M%#GitViewStatusUnstaged#M ', gutter(entries, 1))
  eq('%#GitViewStatusStaged# %#GitViewStatusUnstaged#D ', gutter(entries, 2))
end)

test('list: an untracked file gets both letters in one color', function()
  eq('%#GitViewStatusUntracked#?? ', gutter({ entry('?', '?', 'new.txt') }, 1))
end)

-- Every row is three columns wide, including the ones standing for no file, or
-- the paths would not line up.
test('list: a row with no entry still takes the gutter width', function()
  eq('   ', gutter({}, 1))
end)

test('list: drawing forgets the entries of the previous draw', function()
  local buf = list.create_buffer()
  list.draw(buf, { pane = 'files', root = '/tmp/repo', entries = { entry('M', ' ', 'a.txt'), entry('M', ' ', 'b.txt') } })
  list.draw(buf, { pane = 'files', root = '/tmp/repo', entries = { entry('M', ' ', 'c.txt') } })
  eq({ 'c.txt' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq('c.txt', list.entry_at(buf, 1).path)
  eq(nil, list.entry_at(buf, 2))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('list: state is dropped when the buffer goes', function()
  local buf = list.create_buffer()
  list.draw(buf, { pane = 'files', root = '/tmp/repo', entries = { entry('M', ' ', 'a.txt') } })
  assert(list.state_of(buf), 'state should be registered')
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(nil, list.state_of(buf))
end)

-- `v:lua.require(...).fn()` converts the whole module into a Vim value on every
-- call, so a table on it would be copied each time a window option is evaluated.
test('list: the module holds no table for window options to copy', function()
  for key, value in pairs(list) do
    assert(type(value) ~= 'table', ('list.%s is a table'):format(key))
  end
end)

--- @param status string
--- @param path string
--- @param old_path string?
--- @return gitview.Change
local function change(status, path, old_path)
  return { status = status, path = path, old_path = old_path or path, binary = false }
end

--- @param changes gitview.Change[]
--- @return gitview.ListModel
local function looking_into(changes)
  return {
    pane = 'commits',
    root = '/tmp/repo',
    commits = { commit('abc1234', 'do a thing') },
    scope = { commit = commit('abc1234', 'do a thing'), changes = changes },
  }
end

-- A commit's changes and the uncommitted entries are different shapes, so
-- looking into a commit replaces what the pane holds rather than adding to it.
-- Which commit it is, is named by the 'winbar'.
test('list: looking into a commit replaces the commits pane', function()
  local rows = list.content(looking_into({ change('M', 'a.txt'), change('A', 'b.txt') }))
  eq({ 'a.txt', 'b.txt' }, texts(rows))
  eq({ kind = 'commit_file', index = 2 }, rows[2].target)
end)

-- A commit has one status letter per file, not two, and the width is kept so
-- the paths line up with everything else the list draws.
test('list: a commit file gets one status letter', function()
  local rows = list.content(looking_into({ change('D', 'a.txt') }))
  eq('%#GitViewStatusStaged#D  ', rows[1].gutter)
end)

test('list: a commit file names both sides of a rename', function()
  local rows = list.content(looking_into({ change('R', 'new.txt', 'old.txt') }))
  eq('old.txt -> new.txt', rows[1].text)
end)

-- `git commit --allow-empty` makes one, and it would otherwise show a header
-- and nothing at all.
test('list: an empty commit says so', function()
  local rows = list.content(looking_into({}))
  eq({ list.EMPTY_COMMIT_NOTICE }, texts(rows))
  eq(nil, rows[1].target)
end)

--- What `'statuscolumn'` draws for the first row of a commits pane.
--- @param model gitview.ListModel
--- @return string
local function commits_gutter(model)
  local buf = list.create_buffer()
  list.draw(buf, model)
  local win = vim.api.nvim_open_win(buf, false, { relative = 'editor', row = 0, col = 0, width = 20, height = 5 })
  vim.g.statusline_winid = win
  vim.v.lnum = 1
  local out = list.statuscolumn()
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  return out
end

-- The sidebar is narrow, and a commit row has nothing for the gutter to say.
test("list: commit rows have no gutter, a commit's files do", function()
  local model = { pane = 'commits', root = '/tmp/repo', commits = { commit('abc1234', 'x') } }
  eq('', commits_gutter(model))
  model.scope = { commit = commit('abc1234', 'x'), changes = { change('M', 'a.txt') } }
  eq('%#GitViewStatusStaged#M  ', commits_gutter(model))
end)
