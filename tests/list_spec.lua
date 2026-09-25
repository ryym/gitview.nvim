local list = require('unidiff.ui.list')

local test, eq = _G.test, _G.eq

--- @param x string index status
--- @param y string worktree status
--- @param path string
--- @param head_path string?
--- @return unidiff.StatusEntry
local function entry(x, y, path, head_path)
  return {
    path = path,
    head_path = head_path or path,
    index_status = x,
    worktree_status = y,
    in_index = true,
    binary = false,
  }
end

--- @param rows unidiff.ListRow[]
--- @return string[]
local function texts(rows)
  return vim.tbl_map(function(r)
    return r.text
  end, rows)
end

--- @param sha string
--- @param subject string
--- @return unidiff.Commit
local function commit(sha, subject)
  return { sha = sha, parents = { 'p' }, subject = subject, author = 'a', when = 'now' }
end

-- The buffer holds paths and nothing else, so that yanking a row gives
-- something pasteable. The status letters live in the 'statuscolumn'.
test('list: rows are paths, without their status letters', function()
  local rows = list.content({ entries = { entry('M', ' ', 'a.txt'), entry('?', '?', 'new.txt') } })
  eq({ 'a.txt', 'new.txt' }, texts(rows))
end)

test('list: a rename names both sides', function()
  eq({ 'old.txt -> new.txt' }, texts(list.content({ entries = { entry('R', ' ', 'new.txt', 'old.txt') } })))
end)

test('list: every row maps back to its entry', function()
  local rows = list.content({ entries = { entry('M', ' ', 'a.txt'), entry(' ', 'M', 'b.txt') } })
  eq({ kind = 'file', index = 1 }, rows[1].target)
  eq({ kind = 'file', index = 2 }, rows[2].target)
end)

-- The notice is a buffer row like any other, but it stands for no file, so
-- nothing may resolve it to an entry.
test('list: an empty repository shows a notice that maps to nothing', function()
  local rows = list.content({ entries = {} })
  eq({ list.EMPTY_NOTICE }, texts(rows))
  eq(nil, rows[1].target)
end)

-- A commit row states its own sha and subject, so yanking one gives something
-- that identifies the commit elsewhere.
test('list: commits are listed below the files, under a header', function()
  local rows = list.content({ entries = { entry('M', ' ', 'a.txt') }, commits = { commit('abc1234', 'do a thing') } })
  eq({ 'a.txt', '', list.COMMITS_HEADER, 'abc1234 do a thing' }, texts(rows))
  eq({ kind = 'commit', index = 1 }, rows[4].target)
end)

-- The blank row and the header stand for nothing, the way the empty notice
-- does, so a cursor on either resolves to no selection at all.
test('list: the commit section separator and header map to nothing', function()
  local rows = list.content({ entries = { entry('M', ' ', 'a.txt') }, commits = { commit('abc1234', 'x') } })
  eq(nil, rows[2].target)
  eq(nil, rows[3].target)
  eq(true, rows[3].header)
end)

test('list: no commits means no header and no separator', function()
  eq({ 'a.txt' }, texts(list.content({ entries = { entry('M', ' ', 'a.txt') }, commits = {} })))
end)

-- A commit has no index and no working tree, so there are no two letters to
-- show; the width is kept so the rows still line up.
test('list: a commit row has no status letters', function()
  local rows = list.content({ commits = { commit('abc1234', 'x') } })
  eq(nil, rows[#rows].gutter)
end)

test('list: a target resolves back to the row showing it', function()
  local buf = list.create_buffer()
  list.draw(buf, { root = '/tmp/repo', entries = { entry('M', ' ', 'a.txt') }, commits = { commit('abc1234', 'x') } })
  eq(4, list.row_of(buf, { kind = 'commit', index = 1 }))
  eq(1, list.row_of(buf, { kind = 'file', index = 1 }))
  eq(nil, list.row_of(buf, { kind = 'commit', index = 2 }))
  eq({ kind = 'commit', index = 1 }, list.target_at(buf, 4))
  -- the header row
  eq(nil, list.target_at(buf, 3))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

--- @param entries unidiff.StatusEntry[]
--- @param lnum integer
--- @return string
local function gutter(entries, lnum)
  local buf = list.create_buffer()
  list.draw(buf, { root = '/tmp/repo', entries = entries })
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
  eq('%#UnidiffStatusStaged#M%#UnidiffStatusUnstaged#M ', gutter(entries, 1))
  eq('%#UnidiffStatusStaged# %#UnidiffStatusUnstaged#D ', gutter(entries, 2))
end)

test('list: an untracked file gets both letters in one color', function()
  eq('%#UnidiffStatusUntracked#?? ', gutter({ entry('?', '?', 'new.txt') }, 1))
end)

-- Every row is three columns wide, including the ones standing for no file, or
-- the paths would not line up.
test('list: a row with no entry still takes the gutter width', function()
  eq('   ', gutter({}, 1))
end)

test('list: drawing forgets the entries of the previous draw', function()
  local buf = list.create_buffer()
  list.draw(buf, { root = '/tmp/repo', entries = { entry('M', ' ', 'a.txt'), entry('M', ' ', 'b.txt') } })
  list.draw(buf, { root = '/tmp/repo', entries = { entry('M', ' ', 'c.txt') } })
  eq({ 'c.txt' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq('c.txt', list.entry_at(buf, 1).path)
  eq(nil, list.entry_at(buf, 2))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('list: state is dropped when the buffer goes', function()
  local buf = list.create_buffer()
  list.draw(buf, { root = '/tmp/repo', entries = { entry('M', ' ', 'a.txt') } })
  assert(list.state[buf], 'state should be registered')
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(nil, list.state[buf])
end)

--- @param status string
--- @param path string
--- @param old_path string?
--- @return unidiff.Change
local function change(status, path, old_path)
  return { status = status, path = path, old_path = old_path or path, binary = false }
end

--- @param changes unidiff.Change[]
--- @return unidiff.ListModel
local function looking_into(changes)
  return {
    root = '/tmp/repo',
    entries = { entry('M', ' ', 'uncommitted.txt') },
    commits = { commit('abc1234', 'do a thing') },
    scope = { commit = commit('abc1234', 'do a thing'), changes = changes },
  }
end

-- A commit's changes and the uncommitted entries are different shapes, so
-- looking into a commit replaces the list rather than extending it.
test('list: looking into a commit replaces the whole list', function()
  local rows = list.content(looking_into({ change('M', 'a.txt'), change('A', 'b.txt') }))
  eq({ 'abc1234 do a thing', 'a.txt', 'b.txt' }, texts(rows))
  eq(true, rows[1].header)
  eq(nil, rows[1].target)
  eq({ kind = 'commit_file', index = 2 }, rows[3].target)
end)

-- A commit has one status letter per file, not two, and the width is kept so
-- the paths line up with everything else the list draws.
test('list: a commit file gets one status letter', function()
  local rows = list.content(looking_into({ change('D', 'a.txt') }))
  eq('%#UnidiffStatusStaged#D  ', rows[2].gutter)
end)

test('list: a commit file names both sides of a rename', function()
  local rows = list.content(looking_into({ change('R', 'new.txt', 'old.txt') }))
  eq('old.txt -> new.txt', rows[2].text)
end)

-- `git commit --allow-empty` makes one, and it would otherwise show a header
-- and nothing at all.
test('list: an empty commit says so', function()
  local rows = list.content(looking_into({}))
  eq({ 'abc1234 do a thing', list.EMPTY_COMMIT_NOTICE }, texts(rows))
  eq(nil, rows[2].target)
end)
