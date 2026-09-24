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

-- The buffer holds paths and nothing else, so that yanking a row gives
-- something pasteable. The status letters live in the 'statuscolumn'.
test('list: rows are paths, without their status letters', function()
  local c = list.content({ entry('M', ' ', 'a.txt'), entry('?', '?', 'new.txt') })
  eq({ 'a.txt', 'new.txt' }, c.lines)
end)

test('list: a rename names both sides', function()
  local c = list.content({ entry('R', ' ', 'new.txt', 'old.txt') })
  eq({ 'old.txt -> new.txt' }, c.lines)
end)

test('list: every row maps back to its entry', function()
  local entries = { entry('M', ' ', 'a.txt'), entry(' ', 'M', 'b.txt') }
  local c = list.content(entries)
  eq({ 1, 2 }, c.rows)
end)

-- The notice is a buffer row like any other, but it stands for no file, so
-- nothing may resolve it to an entry.
test('list: an empty repository shows a notice that maps to nothing', function()
  local c = list.content({})
  eq({ list.EMPTY_NOTICE }, c.lines)
  eq({}, c.rows)
end)

--- @param entries unidiff.StatusEntry[]
--- @param lnum integer
--- @return string
local function gutter(entries, lnum)
  local buf = list.create_buffer()
  list.draw(buf, '/tmp/repo', entries)
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
  list.draw(buf, '/tmp/repo', { entry('M', ' ', 'a.txt'), entry('M', ' ', 'b.txt') })
  list.draw(buf, '/tmp/repo', { entry('M', ' ', 'c.txt') })
  eq({ 'c.txt' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq('c.txt', list.entry_at(buf, 1).path)
  eq(nil, list.entry_at(buf, 2))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('list: state is dropped when the buffer goes', function()
  local buf = list.create_buffer()
  list.draw(buf, '/tmp/repo', { entry('M', ' ', 'a.txt') })
  assert(list.state[buf], 'state should be registered')
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(nil, list.state[buf])
end)
