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
  return { sha = sha, full_sha = sha .. 'ffff', parents = { 'p' }, subject = subject, author = 'a', when = 'now' }
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

-- The sha is told apart from the subject, and the working tree's zeros, which
-- are no sha, stay faded with the rest of their row.
test('list: the sha of a commit row is colored', function()
  local rows = list.content({ pane = 'commits', worktree = true, commits = { commit('abc1234', 'x') } })
  eq({ from = 0, to = 7, group = 'GitviewCommitSha' }, rows[2].spans[#rows[2].spans])
  for _, span in ipairs(rows[1].spans) do
    assert(span.group ~= 'GitviewCommitSha', 'the zeros are no sha')
  end
end)

--- What `paint_upstream` drew: the rows whose sha it faded, and the virtual
--- lines it hung below rows, all 0-based.
--- @param buf integer
--- @return {pushed:integer[], lines:table<integer, string>}
local function upstream_paint(buf)
  local ns = vim.api.nvim_create_namespace('gitview.ui.list.upstream')
  local out = { pushed = {}, lines = {} }
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].hl_group == 'GitviewCommitShaPushed' then
      out.pushed[#out.pushed + 1] = m[2]
    end
    if m[4].virt_lines then
      assert(not m[4].virt_lines_above, 'a line above the first row is not shown')
      local text = {}
      for _, chunk in ipairs(m[4].virt_lines[1]) do
        text[#text + 1] = chunk[1]
      end
      out.lines[m[2]] = table.concat(text)
    end
  end
  return out
end

--- A commits pane drawn with `commits` and painted for `upstream`.
--- @param commits gitview.Commit[]
--- @param upstream gitview.Upstream?
--- @param unpushed table<string, true>?
--- @param worktree boolean?
--- @return integer buf
local function painted(commits, upstream, unpushed, worktree)
  local buf = list.create_buffer()
  list.draw(buf, { pane = 'commits', root = '/tmp/repo', worktree = worktree, commits = commits })
  list.paint_upstream(buf, upstream, unpushed)
  return buf
end

-- What is pushed is faded, once there is an upstream to tell it by.
test('list: a pushed sha is faded', function()
  local a, b = commit('abc1234', 'new'), commit('def5678', 'old')
  local buf = painted({ a, b }, { sha = b.full_sha, name = 'origin/main' }, { [a.full_sha] = true })
  eq({ 1 }, upstream_paint(buf).pushed)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('list: without an upstream no sha is faded', function()
  local buf = painted({ commit('abc1234', 'x') }, nil, nil)
  eq({ pushed = {}, lines = {} }, upstream_paint(buf))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- The line says where the upstream is, which is not always below the last
-- unpushed row: a merge from it can leave pushed commits between unpushed ones.
-- It hangs below the row above, since a line above the first row of a buffer
-- is not shown until the window is scrolled onto it.
test('list: the upstream is named above the commit it points at', function()
  local a, b, c = commit('abc1234', 'merge'), commit('bcd2345', 'theirs'), commit('cde3456', 'mine')
  local buf = painted(
    { a, b, c },
    { sha = b.full_sha, name = 'origin/main' },
    { [a.full_sha] = true, [c.full_sha] = true }
  )
  local lines = upstream_paint(buf).lines
  eq({ 0 }, vim.tbl_keys(lines))
  assert(vim.startswith(lines[0], '── origin/main ─'), lines[0])
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('list: an upstream the list does not reach is not named', function()
  local buf = painted({ commit('abc1234', 'x') }, { sha = 'elsewhere', name = 'origin/main' }, {})
  eq({}, upstream_paint(buf).lines)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- HEAD's row is the first without the working-tree row, and has no row above.
test('list: the upstream is named only below a row', function()
  local a = commit('abc1234', 'x')
  local upstream = { sha = a.full_sha, name = 'origin/main' }
  local buf = painted({ a }, upstream, {}, true)
  eq({ 0 }, vim.tbl_keys(upstream_paint(buf).lines))
  vim.api.nvim_buf_delete(buf, { force = true })
  buf = painted({ a }, upstream, {})
  eq({}, upstream_paint(buf).lines)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('list: the working-tree row is faded as a whole', function()
  local rows = list.content({ pane = 'commits', worktree = true, commits = { commit('abc1234', 'x') } })
  eq({ from = 0, to = #rows[1].text, group = 'GitviewCommitWorktree' }, rows[1].spans[#rows[1].spans])
  for _, span in ipairs(rows[2].spans) do
    assert(span.group ~= 'GitviewCommitWorktree', 'a commit row is not faded')
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
    return m[4].hl_group == 'GitviewCommitWorktree'
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
  eq('%#GitviewStatusStaged#M%#GitviewStatusUnstaged#M ', gutter(entries, 1))
  eq('%#GitviewStatusStaged# %#GitviewStatusUnstaged#D ', gutter(entries, 2))
end)

test('list: an untracked file gets both letters in one color', function()
  eq('%#GitviewStatusUntracked#?? ', gutter({ entry('?', '?', 'new.txt') }, 1))
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
  eq('%#GitviewStatusStaged#D  ', rows[1].gutter)
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
  eq('%#GitviewStatusStaged#M  ', commits_gutter(model))
end)

--- @param rows gitview.ListRow[]
--- @param i integer
--- @return {from:integer, to:integer}[]
local function concealed(rows, i)
  local out = {}
  for _, sp in ipairs(rows[i].spans or {}) do
    if sp.conceal then
      out[#out + 1] = { from = sp.from, to = sp.to }
    end
  end
  return out
end

test('list: a tree keeps each row a whole path and hides the parent part', function()
  local rows = list.content({
    pane = 'files',
    tree = true,
    entries = { entry('M', ' ', 'README.md'), entry('M', ' ', 'lua/gitview/ui/list.lua') },
  })
  eq({ './', 'README.md', 'lua/gitview/ui/', 'lua/gitview/ui/list.lua' }, texts(rows))
  eq({}, concealed(rows, 2))
  eq({}, concealed(rows, 3))
  eq({ { from = 0, to = 15 } }, concealed(rows, 4))
  eq({ 0, 0, 0, 1 }, vim.tbl_map(function(r)
    return r.indent
  end, rows))
  -- colored from the name on, past what is hidden
  eq(15, rows[4].subject)
end)

-- Neither the diff nor the status letters have anything to say about a
-- directory, so its row has no subject to color and no gutter.
test('list: a directory row stands for the first file in it', function()
  local rows = list.content({
    pane = 'files',
    tree = true,
    entries = { entry(' ', 'M', 'a.txt'), entry(' ', 'M', 'src/x/b.txt'), entry(' ', 'M', 'src/y.txt') },
  })
  eq({ './', 'a.txt', 'src/', 'src/x/', 'src/x/b.txt', 'src/y.txt' }, texts(rows))
  eq({ kind = 'dir', index = 1, path = '' }, rows[1].target)
  eq({ kind = 'dir', index = 2, path = 'src' }, rows[3].target)
  eq({ kind = 'dir', index = 2, path = 'src/x' }, rows[4].target)
  eq({ { from = 0, to = 4 } }, concealed(rows, 4))
  eq(nil, rows[3].subject)
  eq(nil, rows[3].gutter)
  -- in front of the name: a directory's mark, or a file's status letters
  eq({ '▼ ', ' M ', '▼ ', '▼ ', ' M ', ' M ' }, vim.tbl_map(function(r)
    return table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, r.lead))
  end, rows))
  eq({ 'GitviewStatusStaged', 'GitviewStatusUnstaged' }, { rows[2].lead[1][2], rows[2].lead[2][2] })
  -- which leaves the gutter with nothing to draw
  eq(nil, rows[2].gutter)
  eq({ kind = 'file', index = 3 }, rows[6].target)
end)

test('list: a rename within a directory hides the directory on both sides', function()
  local rows = list.content({
    pane = 'files',
    tree = true,
    entries = { entry('R', ' ', 'src/new.lua', 'src/old.lua') },
  })
  eq('src/old.lua -> src/new.lua', rows[3].text)
  eq({ { from = 0, to = 4 }, { from = 15, to = 19 } }, concealed(rows, 3))
  eq(4, rows[3].subject)
end)

-- Where the file came from is part of what the rename says.
test('list: a rename across directories is shown whole', function()
  local rows = list.content({
    pane = 'files',
    tree = true,
    entries = { entry('R', ' ', 'src/new.lua', 'lib/old.lua') },
  })
  eq('lib/old.lua -> src/new.lua', rows[3].text)
  eq({}, concealed(rows, 3))
  eq(0, rows[3].subject)
end)

test('list: a commit looked into lists its files as a tree too', function()
  local rows = list.content({
    pane = 'commits',
    tree = true,
    scope = {
      range = { old = 'a', new = 'b' },
      label = 'b',
      at = 'b',
      changes = { { status = 'M', path = 'lib/x.lua', old_path = 'lib/x.lua', binary = false } },
    },
  })
  eq({ './', 'lib/', 'lib/x.lua' }, texts(rows))
  eq({ kind = 'commit_dir', index = 1, path = 'lib' }, rows[2].target)
  eq({ kind = 'commit_file', index = 1 }, rows[3].target)
end)

-- The tree draws over the rows; a flat list is what it always was.
test('list: a flat list has no directory rows', function()
  local rows = list.content({ pane = 'files', entries = { entry('M', ' ', 'src/a.txt') } })
  eq({ 'src/a.txt' }, texts(rows))
  eq(nil, rows[1].indent)
  eq(nil, rows[1].spans)
end)
