local config = require('gitview.config')
local list = require('gitview.ui.list')
local render = require('gitview.diff.render')
local session = require('gitview.ui.session')
local helpers = dofile('tests/helpers.lua')

local test, eq = _G.test, _G.eq

--- @param s gitview.Session
local function settle(s)
  local done = vim.wait(5000, function()
    return not s.reading
  end)
  assert(done, 'the status was never read')
end

--- Open a session against a fresh repository, run `fn`, then close it.
--- @param setup fun(repo: gitview.TestRepo)
--- @param fn fun(s: gitview.Session, repo: gitview.TestRepo)
--- @param opts? {tree?:boolean} `tree` to lay the lists out as trees
local function with_session(setup, fn, opts)
  local style = config.values.list_style
  if opts and opts.tree then
    config.values.list_style = 'tree'
  end
  helpers.with_repo(function(repo)
    setup(repo)
    local previous = vim.fn.getcwd()
    vim.cmd.lcd(repo.root)
    local s = session.open()
    local ok, err = pcall(function()
      assert(s, 'no session opened')
      settle(s)
      fn(s, repo)
      -- A view still being read would go on running git in a repository about
      -- to be removed.
      vim.wait(5000, function()
        return not s.loading and not s.pending
      end)
    end)
    if s and vim.api.nvim_tabpage_is_valid(s.tab) then
      session.close(s)
    end
    vim.cmd.lcd(previous)
    config.values.list_style = style
    if not ok then
      error(err, 0)
    end
  end)
end

--- @param s gitview.Session
--- @return string[]
local function rows(s)
  return vim.api.nvim_buf_get_lines(s.files_buf, 0, -1, false)
end

--- @param s gitview.Session
--- @return string[]
local function commit_rows(s)
  return vim.api.nvim_buf_get_lines(s.commits_buf, 0, -1, false)
end

--- @param s gitview.Session
--- @return string[]
local function diff_rows(s)
  return vim.api.nvim_buf_get_lines(s.diff_buf, 0, -1, false)
end

--- Press keys in a pane, so that the buffer-local mapping is what is tested.
--- @param s gitview.Session
--- @param keys string
--- @param win integer? the files pane by default
local function press(s, keys, win)
  vim.api.nvim_set_current_win(win or s.files_win)
  vim.cmd.normal(vim.keycode(keys))
  settle(s)
end

--- Put the commits pane's cursor on a row and follow it, as moving there does.
--- @param s gitview.Session
--- @param target gitview.ListTarget
local function goto_row(s, target)
  vim.api.nvim_set_current_win(s.commits_win)
  local row = assert(list.row_of(s.commits_buf, target))
  vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
  session.follow_cursor(s, s.commits_win)
end

--- @param s gitview.Session
--- @param index integer
local function goto_commit(s, index)
  goto_row(s, { kind = 'commit', index = index })
end

--- @param s gitview.Session
local function goto_worktree(s)
  goto_row(s, { kind = 'worktree', index = 1 })
end

--- @param s gitview.Session
--- @param win integer
--- @return string
local function winbar(s, win)
  vim.g.statusline_winid = win
  if win == s.diff_win then
    local bar = render.winbar()
    return (bar:gsub('%%#%w+#', ''):gsub('%%%*', ''):gsub('%%<$', ''))
  end
  return (list.winbar():gsub('%%#%w+#', ''))
end

--- What `fn` said through `vim.notify`, without the prefix every message has.
--- @param fn fun()
--- @return string[]
local function notified(fn)
  local notify = vim.notify
  local messages = {}
  vim.notify = function(msg)
    messages[#messages + 1] = (msg:gsub('^gitview: ', ''))
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return messages
end

--- Three commits and an uncommitted edit:
---
---   3 first   a.lua
---   2 second  a.lua, b.lua
---   1 third   c.lua
---   working tree: a.lua edited, loose.lua untracked
local function history(repo)
  repo.write('a.lua', { 'return 1' })
  repo.commit('first')
  repo.write('a.lua', { 'return 2' })
  repo.write('b.lua', { 'return 2' })
  repo.commit('second')
  repo.write('c.lua', { 'return 3' })
  repo.commit('third')
  repo.write('a.lua', { 'return 4' })
  repo.write('loose.lua', { 'return 5' })
end

test('review: `gr` on a commit reviews that commit alone in the files pane', function()
  with_session(history, function(s)
    goto_commit(s, 2)
    press(s, 'gr', s.commits_win)
    eq({ 'a.lua', 'b.lua' }, rows(s))
    eq(s.files_win, vim.api.nvim_get_current_win())
    eq({ kind = 'commit_file', index = 1, review = true }, s.selected)
    eq((' review %s second'):format(s.commits[2].sha), winbar(s, s.files_win))
    -- the commits pane is left as it was
    eq(s.commits[1].sha .. ' third', commit_rows(s)[2])
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('return 2', 1, true), text)
  end)
end)

test('review: `gr` on a range reviews it from the older end', function()
  with_session(history, function(s)
    goto_commit(s, 3)
    press(s, 'm', s.commits_win)
    goto_commit(s, 2)
    press(s, 'gr', s.commits_win)
    eq({ 'a.lua', 'b.lua' }, rows(s))
    eq((' review %s^..%s'):format(s.commits[3].sha, s.commits[2].sha), winbar(s, s.files_win))
    -- the range is the review's now
    eq(nil, s.mark)
  end)
end)

test('review: the working tree alone is reviewed from the commit HEAD is on', function()
  with_session(history, function(s, repo)
    local head = s.commits[1]
    goto_worktree(s)
    press(s, 'gr', s.commits_win)
    eq({ 'a.lua', 'loose.lua' }, rows(s))
    eq((' review %s..working tree'):format(head.sha), winbar(s, s.files_win))
    -- what is committed meanwhile stays in the review
    repo.commit('fourth')
    session.refresh(s)
    settle(s)
    eq({ 'a.lua', 'loose.lua' }, rows(s))
    repo.write('later.lua', { 'return 6' })
    session.refresh(s)
    settle(s)
    eq({ 'a.lua', 'later.lua', 'loose.lua' }, rows(s))
  end)
end)

test('review: `gr` while looking into a range reviews that range instead', function()
  with_session(history, function(s)
    goto_commit(s, 2)
    press(s, '<CR>', s.commits_win)
    eq({ 'a.lua', 'b.lua' }, commit_rows(s))
    press(s, 'gr', s.commits_win)
    eq(nil, s.scope)
    eq({ 'a.lua', 'b.lua' }, rows(s))
    eq((' review %s second'):format(s.commits[2].sha), winbar(s, s.files_win))
    -- the commits pane is back on the commit it was looked into from
    local row = vim.api.nvim_win_get_cursor(s.commits_win)[1]
    eq({ kind = 'commit', index = 2 }, list.target_at(s.commits_buf, row))
  end)
end)

test('review: a tree review starts on its first file rather than its root', function()
  with_session(history, function(s)
    goto_commit(s, 2)
    press(s, 'gr', s.commits_win)
    eq({ './', 'a.lua', 'b.lua' }, rows(s))
    eq({ kind = 'commit_file', index = 1, review = true }, s.selected)
  end, { tree = true })
end)

test('review: a range with no change is reviewed all the same', function()
  with_session(function(repo)
    repo.write('a.lua', { 'return 1' })
    repo.commit('first')
  end, function(s, repo)
    goto_worktree(s)
    press(s, 'gr', s.commits_win)
    eq({ list.EMPTY_REVIEW_NOTICE }, rows(s))
    eq(list.EMPTY_REVIEW_NOTICE, diff_rows(s)[1])
    repo.write('a.lua', { 'return 2' })
    session.refresh(s)
    settle(s)
    eq({ 'a.lua' }, rows(s))
  end)
end)

test('review: `<BS>` ends it and goes back to the file selected before', function()
  with_session(history, function(s)
    session.select(s, 2)
    goto_commit(s, 2)
    press(s, 'gr', s.commits_win)
    press(s, '<BS>')
    eq(nil, s.review)
    eq({ 'a.lua', 'loose.lua' }, rows(s))
    eq({ kind = 'file', index = 2 }, s.selected)
    eq(' test-repo   2 files', winbar(s, s.files_win))
  end)
end)

test('review: starting over from the commits pane keeps where it goes back to', function()
  with_session(history, function(s)
    session.select(s, 2)
    goto_commit(s, 2)
    press(s, 'gr', s.commits_win)
    goto_commit(s, 1)
    press(s, 'gr', s.commits_win)
    eq({ 'c.lua' }, rows(s))
    press(s, '<BS>')
    eq({ kind = 'file', index = 2 }, s.selected)
  end)
end)

test('review: a range across a fork says so', function()
  with_session(function(repo)
    repo.write('base.txt', { 'base' })
    repo.commit('first')
    repo.git('checkout', '-q', '-b', 'side')
    repo.write('side.txt', { 'side' })
    repo.commit('on side')
    repo.git('checkout', '-q', '-')
    repo.write('main.txt', { 'main' })
    repo.commit('on main')
    repo.git('merge', '-q', '--no-ff', 'side', '-m', 'merge side')
  end, function(s)
    -- `on side` against `on main`, the one above it in the list
    local side = 0
    for i, c in ipairs(s.commits) do
      if c.subject == 'on side' then
        side = i
      end
    end
    goto_commit(s, side)
    press(s, 'm', s.commits_win)
    goto_commit(s, side - 1)
    press(s, 'gr', s.commits_win)
    assert(winbar(s, s.files_win):find('diverged$'), winbar(s, s.files_win))
    assert(winbar(s, s.diff_win):find('diverged', 1, true), winbar(s, s.diff_win))
  end)
end)

-- The two lists can hold the same range, and the diff must not take a file of
-- one for the same file of the other.
test('review: a file under review is not the same file looked into', function()
  with_session(history, function(s)
    goto_commit(s, 2)
    press(s, 'gr', s.commits_win)
    local reviewed = s.shown
    goto_commit(s, 2)
    press(s, '<CR>', s.commits_win)
    goto_row(s, { kind = 'commit_file', index = 1 })
    assert(not vim.deep_equal(reviewed, s.shown), vim.inspect(s.shown))
    eq(reviewed.id, s.shown.id)
  end)
end)

test('review: nothing is staged from it', function()
  with_session(history, function(s, repo)
    goto_worktree(s)
    press(s, 'gr', s.commits_win)
    eq({ 'nothing is staged during a review' }, notified(function()
      press(s, 's')
    end))
    vim.api.nvim_set_current_win(s.diff_win)
    eq({ 'nothing is staged during a review' }, notified(function()
      vim.cmd.normal('s')
    end))
    eq(' M a.lua\n?? loose.lua\n', repo.git('status', '--short'))
  end)
end)

test('review: the layer is not switched during it', function()
  with_session(history, function(s)
    goto_commit(s, 2)
    press(s, 'gr', s.commits_win)
    eq({ 'the layer cannot be switched during a review' }, notified(function()
      press(s, 'gs')
    end))
    eq('both', s.layer)
  end)
end)

test('review: the working-tree row is not looked into during it', function()
  with_session(history, function(s)
    goto_commit(s, 2)
    press(s, 'gr', s.commits_win)
    goto_worktree(s)
    eq({ 'the uncommitted files are not listed during a review' }, notified(function()
      press(s, '<CR>', s.commits_win)
    end))
    eq(s.commits_win, vim.api.nvim_get_current_win())
  end)
end)

test('review: `]r` from one of its files shows no commit', function()
  with_session(history, function(s)
    goto_commit(s, 2)
    press(s, 'gr', s.commits_win)
    vim.api.nvim_set_current_win(s.diff_win)
    eq({ 'no commit is shown' }, notified(function()
      vim.cmd.normal(']r')
    end))
    eq({ kind = 'commit_file', index = 1, review = true }, s.selected)
  end)
end)

test('review: `]f` from one of its files moves down the files pane', function()
  with_session(history, function(s)
    goto_commit(s, 2)
    press(s, 'gr', s.commits_win)
    vim.api.nvim_set_current_win(s.diff_win)
    vim.cmd.normal(']f')
    eq({ kind = 'commit_file', index = 2, review = true }, s.selected)
    eq(2, vim.api.nvim_win_get_cursor(s.files_win)[1])
  end)
end)

test('review: `gr` in the files pane starts nothing', function()
  with_session(history, function(s)
    eq({ 'a review is started from the commits pane' }, notified(function()
      press(s, 'gr')
    end))
    eq(nil, s.review)
  end)
end)
