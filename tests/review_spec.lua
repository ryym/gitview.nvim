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
    eq((' review %s second   0/2'):format(s.commits[2].sha), winbar(s, s.files_win))
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
    eq((' review %s^..%s   0/2'):format(s.commits[3].sha, s.commits[2].sha), winbar(s, s.files_win))
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
    eq((' review %s..working tree   0/2'):format(head.sha), winbar(s, s.files_win))
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
    eq((' review %s second   0/2'):format(s.commits[2].sha), winbar(s, s.files_win))
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
    eq({ 'a review is started from the commits window' }, notified(function()
      press(s, 'gr')
    end))
    eq(nil, s.review)
  end)
end)

local checks = require('gitview.review')

test('review.toggle checks every path, or takes them off once all are', function()
  local c = { ['a'] = {} }
  eq(true, checks.toggle(c, { 'a', 'b' }))
  eq({ 'a', 'b' }, vim.fn.sort(vim.tbl_keys(c)))
  eq(false, checks.toggle(c, { 'a', 'b' }))
  eq({}, c)
end)

test('review.next_open goes round from the other end', function()
  local c = { ['b'] = {} }
  local paths = { 'a', 'b', 'c' }
  eq(3, checks.next_open(c, paths, 1, 1))
  eq(1, checks.next_open(c, paths, 3, 1))
  eq(3, checks.next_open(c, paths, 1, -1))
  eq(1, checks.next_open(c, paths, 0, 1))
  eq(3, checks.next_open(c, paths, 4, -1))
  -- the file it starts from comes last
  eq(1, checks.next_open({ b = {}, c = {} }, paths, 1, 1))
  eq(nil, checks.next_open({ a = {}, b = {}, c = {} }, paths, 1, 1))
end)

--- The review's mark on each row of the files pane, `''` for none.
--- @param s gitview.Session
--- @return string[]
local function marks(s)
  return vim.tbl_map(function(r)
    return r.check and r.check[1] or ''
  end, assert(list.state_of(s.files_buf)).rows)
end

--- Start reviewing commit 2 of `history`, which changed a.lua and b.lua.
--- @param s gitview.Session
local function review_second(s)
  goto_commit(s, 2)
  press(s, 'gr', s.commits_win)
end

--- Answer `vim.fn.confirm` with `answer` while `fn` runs, and say what was asked.
--- @param answer integer
--- @param fn fun()
--- @return string[]
local function confirming(answer, fn)
  local confirm = vim.fn.confirm
  local asked = {}
  vim.fn.confirm = function(msg)
    asked[#asked + 1] = msg
    return answer
  end
  local ok, err = pcall(fn)
  vim.fn.confirm = confirm
  assert(ok, err)
  return asked
end

test('review: `x` in the list checks a file off and counts it', function()
  with_session(history, function(s)
    review_second(s)
    press(s, 'x')
    eq({ '✓', '' }, marks(s))
    eq((' review %s second   1/2'):format(s.commits[2].sha), winbar(s, s.files_win))
    press(s, 'x')
    eq({ '', '' }, marks(s))
  end)
end)

test('review: `x` on a directory checks off every file in it', function()
  with_session(history, function(s)
    review_second(s)
    -- the root, with one of its files checked already
    press(s, 'jx')
    press(s, 'ggx')
    eq({ './', 'a.lua', 'b.lua' }, rows(s))
    assert(winbar(s, s.files_win):find('2/2', 1, true), winbar(s, s.files_win))
    press(s, 'ggx')
    assert(winbar(s, s.files_win):find('0/2', 1, true), winbar(s, s.files_win))
  end, { tree = true })
end)

test('review: `x` over a selection checks off every file in it', function()
  with_session(history, function(s)
    review_second(s)
    press(s, 'ggVjx')
    eq({ '✓', '✓' }, marks(s))
  end)
end)

test('review: `x` in the diff checks the file off and goes on to the next', function()
  with_session(history, function(s)
    review_second(s)
    vim.api.nvim_set_current_win(s.diff_win)
    vim.cmd.normal('x')
    eq({ kind = 'commit_file', index = 2, review = true }, s.selected)
    eq(s.diff_win, vim.api.nvim_get_current_win())
    eq({ '✓', '' }, marks(s))
    -- the last one leaves nothing to go on to
    eq({ 'every file is checked' }, notified(function()
      vim.cmd.normal('x')
    end))
    -- taking a check off stays on the file
    vim.cmd.normal('x')
    eq({ kind = 'commit_file', index = 2, review = true }, s.selected)
    eq({ '✓', '' }, marks(s))
  end)
end)

test('review: `]x` and `[x` go round to the files still to be read', function()
  with_session(history, function(s, repo)
    goto_worktree(s)
    -- three files: a.lua, loose.lua, and one more
    repo.write('more.lua', { 'return 6' })
    session.refresh(s)
    settle(s)
    goto_worktree(s)
    press(s, 'gr', s.commits_win)
    eq({ 'a.lua', 'loose.lua', 'more.lua' }, rows(s))
    press(s, 'jx')
    vim.api.nvim_set_current_win(s.diff_win)
    vim.cmd.normal(']x')
    eq(3, s.selected.index)
    vim.cmd.normal(']x')
    eq(1, s.selected.index)
    vim.cmd.normal('[x')
    eq(3, s.selected.index)
  end)
end)

test('review: a directory marks the headers of the files checked off', function()
  with_session(history, function(s)
    review_second(s)
    session.select(s, 1)
    vim.api.nvim_win_set_cursor(s.files_win, { 1, 0 })
    session.follow_cursor(s, s.files_win)
    vim.wait(1000, function()
      return render.view_of(s.diff_buf) ~= nil and #render.view_of(s.diff_buf).files == 2
    end)
    vim.api.nvim_set_current_win(s.diff_win)
    vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
    vim.cmd.normal('x')
    local view = assert(render.view_of(s.diff_buf))
    -- the cursor goes on to the next file's header, in the same view
    eq(view.files[2].row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
    local ns = vim.api.nvim_create_namespace('gitview.diff.marks')
    local marks = vim.api.nvim_buf_get_extmarks(s.diff_buf, ns, 0, -1, { details = true })
    eq(1, #marks)
    eq(view.files[1].row - 1, marks[1][2])
    eq('✓ ', marks[1][4].virt_text[1][1])
    -- on the header's band and in its weight, which virtual text does not take
    -- by itself
    eq(
      { 'GitviewFileHeaderBg', 'GitviewFileHeader', 'GitviewReviewedMark' },
      marks[1][4].virt_text[1][2]
    )
  end, { tree = true })
end)

test('review: `x` over rows of several files in the diff checks each off', function()
  with_session(history, function(s)
    review_second(s)
    vim.api.nvim_win_set_cursor(s.files_win, { 1, 0 })
    session.follow_cursor(s, s.files_win)
    vim.wait(1000, function()
      return render.view_of(s.diff_buf) ~= nil and #render.view_of(s.diff_buf).files == 2
    end)
    local view = assert(render.view_of(s.diff_buf))
    vim.api.nvim_set_current_win(s.diff_win)
    vim.api.nvim_win_set_cursor(s.diff_win, { view.files[1].row, 0 })
    vim.cmd.normal(('V%dGx'):format(view.files[2].row))
    eq({ '✓', '✓', '✓' }, marks(s))
    -- and off again, all of them checked
    vim.api.nvim_win_set_cursor(s.diff_win, { view.files[1].row, 0 })
    vim.cmd.normal(('V%dGx'):format(view.files[2].row))
    eq({ '', '', '' }, marks(s))
  end, { tree = true })
end)

--- The row of the files pane its cursor is on.
--- @param s gitview.Session
--- @return integer
local function files_cursor(s)
  return vim.api.nvim_win_get_cursor(s.files_win)[1]
end

test('review: `]f` in the files pane goes from file to file, passing over directories', function()
  with_session(history, function(s)
    review_second(s)
    vim.api.nvim_win_set_cursor(s.files_win, { 1, 0 })
    press(s, ']f')
    eq(2, files_cursor(s))
    eq(s.files_win, vim.api.nvim_get_current_win())
    eq({ kind = 'commit_file', index = 1, review = true }, s.selected)
    press(s, ']f')
    eq(3, files_cursor(s))
    eq(2, s.selected.index)
    press(s, ']f')
    eq(3, files_cursor(s))
    press(s, '[f')
    press(s, '[f')
    eq(2, files_cursor(s), 'the directory above is passed over')
  end, { tree = true })
end)

test('review: `]f` in the commits pane goes through the files of a commit looked into', function()
  with_session(history, function(s)
    goto_commit(s, 2)
    local row = vim.api.nvim_win_get_cursor(s.commits_win)[1]
    press(s, ']f', s.commits_win)
    eq(row, vim.api.nvim_win_get_cursor(s.commits_win)[1], 'a commit is no file')
    press(s, '<CR>', s.commits_win)
    press(s, ']f', s.commits_win)
    eq(2, vim.api.nvim_win_get_cursor(s.commits_win)[1])
    eq({ kind = 'commit_file', index = 2 }, s.selected)
  end)
end)

test('review: `]x` in the files pane goes to the next file still to be read', function()
  with_session(history, function(s)
    review_second(s)
    vim.api.nvim_win_set_cursor(s.files_win, { 2, 0 })
    press(s, 'x')
    -- from the directory's row, which stands before its first file
    vim.api.nvim_win_set_cursor(s.files_win, { 1, 0 })
    press(s, ']x')
    eq(3, files_cursor(s))
    eq(s.files_win, vim.api.nvim_get_current_win())
    press(s, 'x')
    eq({ 'every file is checked' }, notified(function()
      press(s, '[x')
    end))
  end, { tree = true })
end)

test('review: `]x` in the files pane says why outside a review', function()
  with_session(history, function(s)
    eq({ 'files are checked off during a review' }, notified(function()
      press(s, ']x')
    end))
  end)
end)

test('review: the same file looked into is not marked', function()
  with_session(history, function(s)
    review_second(s)
    press(s, 'x')
    goto_commit(s, 2)
    press(s, '<CR>', s.commits_win)
    goto_row(s, { kind = 'commit_file', index = 1 })
    local ns = vim.api.nvim_create_namespace('gitview.diff.marks')
    eq({}, vim.api.nvim_buf_get_extmarks(s.diff_buf, ns, 0, -1, {}))
    vim.api.nvim_set_current_win(s.diff_win)
    eq({ 'not a file under review' }, notified(function()
      vim.cmd.normal('x')
    end))
  end)
end)

test('review: ending part way through asks first', function()
  with_session(history, function(s)
    review_second(s)
    press(s, 'x')
    eq({ 'Discard 1 check?' }, confirming(2, function()
      press(s, '<BS>')
    end))
    assert(s.review, 'the review ended')
    confirming(1, function()
      press(s, '<BS>')
    end)
    eq(nil, s.review)
  end)
end)

test('review: ending with every file or none checked asks nothing', function()
  with_session(history, function(s)
    review_second(s)
    eq({}, confirming(2, function()
      press(s, '<BS>')
    end))
    eq(nil, s.review)
    review_second(s)
    press(s, 'ggVjx')
    eq({}, confirming(2, function()
      press(s, '<BS>')
    end))
    eq(nil, s.review)
  end)
end)

test('review: starting over or closing part way through asks first', function()
  with_session(history, function(s)
    review_second(s)
    press(s, 'x')
    goto_commit(s, 1)
    eq({ 'Discard 1 check?' }, confirming(2, function()
      press(s, 'gr', s.commits_win)
    end))
    eq({ 'a.lua', 'b.lua' }, rows(s))
    eq({ 'Discard 1 check?' }, confirming(2, function()
      press(s, 'q')
    end))
    assert(vim.api.nvim_tabpage_is_valid(s.tab), 'the session closed')
  end)
end)

test('review: `x` outside one checks nothing off', function()
  with_session(history, function(s)
    eq({ 'files are checked off during a review' }, notified(function()
      press(s, 'x')
    end))
    vim.api.nvim_set_current_win(s.diff_win)
    eq({ 'files are checked off during a review' }, notified(function()
      vim.cmd.normal('x')
    end))
  end)
end)

--- Start reviewing the working tree of `history` on its own: a.lua edited and
--- loose.lua untracked.
--- @param s gitview.Session
local function review_worktree(s)
  goto_worktree(s)
  press(s, 'gr', s.commits_win)
end

--- Put the files pane's cursor on a row and follow it, as moving there does.
--- @param s gitview.Session
--- @param row integer
local function files_row(s, row)
  vim.api.nvim_win_set_cursor(s.files_win, { row, 0 })
  session.follow_cursor(s, s.files_win)
end

--- @param s gitview.Session
local function refresh(s)
  session.refresh(s)
  settle(s)
end

test('review: a file changed after it was checked off is marked so', function()
  with_session(history, function(s, repo)
    review_worktree(s)
    press(s, 'x')
    eq({ '✓', '' }, marks(s))
    repo.write('a.lua', { 'return 8' })
    refresh(s)
    eq({ '!', '' }, marks(s))
    assert(winbar(s, s.files_win):find('0/2 !1', 1, true), winbar(s, s.files_win))
    -- back as it was read, it is checked again
    repo.write('a.lua', { 'return 4' })
    refresh(s)
    eq({ '✓', '' }, marks(s))
  end)
end)

test('review: a changed file is read again and checked again', function()
  with_session(history, function(s, repo)
    review_worktree(s)
    press(s, 'ggVjx')
    repo.write('a.lua', { 'return 8' })
    refresh(s)
    -- the only one left to read
    files_row(s, 2)
    vim.api.nvim_set_current_win(s.diff_win)
    vim.cmd.normal(']x')
    eq(1, s.selected.index)
    eq({ 'every file is checked' }, notified(function()
      vim.cmd.normal('x')
    end))
    eq({ '✓', '✓' }, marks(s))
  end)
end)

-- The diff of a file ending at the working tree is read from it whenever it is
-- drawn, and a write that goes through no git command triggers no refresh.
test('review: a file drawn again as it is now shows it changed', function()
  with_session(history, function(s, repo)
    review_worktree(s)
    press(s, 'x')
    repo.write('a.lua', { 'return 8' })
    files_row(s, 2)
    files_row(s, 1)
    eq({ '!', '' }, marks(s))
  end)
end)

-- A check records what was on screen: the file may have moved on with nothing
-- having drawn it again.
test('review: checking from the diff records what the diff showed', function()
  with_session(history, function(s, repo)
    review_worktree(s)
    repo.write('a.lua', { 'return 8' })
    vim.api.nvim_set_current_win(s.diff_win)
    vim.cmd.normal('x')
    eq({ '✓', '' }, marks(s))
    refresh(s)
    eq({ '!', '' }, marks(s))
  end)
end)

test('review: a deleted file stays checked while it stays deleted', function()
  with_session(history, function(s, repo)
    vim.fn.delete(repo.root .. '/b.lua')
    refresh(s)
    review_worktree(s)
    eq({ 'a.lua', 'b.lua', 'loose.lua' }, rows(s))
    press(s, 'jx')
    refresh(s)
    eq({ '', '✓', '' }, marks(s))
    repo.write('b.lua', { 'return 2' })
    -- an empty file in its place is not the deletion that was read
    repo.write('b.lua', {})
    refresh(s)
    eq('!', marks(s)[2])
  end)
end)

test('review: a binary file is compared as bytes', function()
  with_session(history, function(s, repo)
    local path = repo.root .. '/blob.bin'
    vim.fn.writefile(vim.fn.list2blob({ 0, 1, 2 }), path)
    refresh(s)
    review_worktree(s)
    eq({ 'a.lua', 'blob.bin', 'loose.lua' }, rows(s))
    press(s, 'jx')
    eq('✓', marks(s)[2])
    vim.fn.writefile(vim.fn.list2blob({ 0, 1, 3 }), path)
    refresh(s)
    eq('!', marks(s)[2])
  end)
end)

test('review: a range between commits is never marked changed', function()
  with_session(history, function(s, repo)
    review_second(s)
    press(s, 'x')
    repo.write('a.lua', { 'return 8' })
    refresh(s)
    eq({ '✓', '' }, marks(s))
  end)
end)

--- What `'statuscolumn'` draws for a row of the files pane, without its
--- highlight groups.
--- @param s gitview.Session
--- @param lnum integer
--- @return string
local function status_column(s, lnum)
  vim.g.statusline_winid = s.files_win
  vim.v.lnum = lnum
  return (list.statuscolumn():gsub('%%#%w+#', ''))
end

test('review: the marks have a column of their own at the left edge', function()
  with_session(history, function(s)
    review_second(s)
    press(s, 'x')
    eq('✓ M  ', status_column(s, 1))
    eq('  A  ', status_column(s, 2))
    -- outside a review there is no such column
    confirming(1, function()
      press(s, '<BS>')
    end)
    eq(' M ', status_column(s, 1))
  end)
end)

test('review: a tree has the column too, the letters staying by the names', function()
  with_session(history, function(s)
    review_second(s)
    eq('  ', status_column(s, 1))
    -- on the first file, below the root
    press(s, 'x')
    eq('✓ ', status_column(s, 2))
  end, { tree = true })
end)

test('review: a directory is marked by the files in it', function()
  with_session(function(repo)
    repo.write('src/a.lua', { 'return 1' })
    repo.write('src/b.lua', { 'return 1' })
    repo.write('top.lua', { 'return 1' })
    repo.commit('first')
    repo.write('src/a.lua', { 'return 2' })
    repo.write('src/b.lua', { 'return 2' })
    repo.write('top.lua', { 'return 2' })
  end, function(s, repo)
    review_worktree(s)
    eq({ './', 'src/', 'src/a.lua', 'src/b.lua', 'top.lua' }, rows(s))
    -- one of two is not enough
    press(s, '3Gx')
    eq({ '', '', '✓', '', '' }, marks(s))
    press(s, '4Gx')
    eq({ '', '✓', '✓', '✓', '' }, marks(s))
    press(s, '5Gx')
    eq({ '✓', '✓', '✓', '✓', '✓' }, marks(s))
    -- one file changed is enough
    repo.write('src/a.lua', { 'return 3' })
    refresh(s)
    eq({ '!', '!', '!', '✓', '✓' }, marks(s))
  end, { tree = true })
end)

--- The highlight groups a row of the files pane is drawn with, its own and
--- those of what is drawn in front of it.
--- @param s gitview.Session
--- @param row integer
--- @return table<string, true>
local function row_groups(s, row)
  local r = assert(list.state_of(s.files_buf)).rows[row]
  local groups = {}
  for _, sp in ipairs(r.spans or {}) do
    if sp.group then
      groups[sp.group] = true
    end
  end
  for _, chunk in ipairs(r.lead or {}) do
    if chunk[2] then
      groups[chunk[2]] = true
    end
  end
  for g in (r.gutter or ''):gmatch('%%#(%w+)#') do
    groups[g] = true
  end
  return groups
end

test('review: a checked row is faded, status letter included', function()
  with_session(history, function(s, repo)
    review_worktree(s)
    press(s, 'x')
    eq({ GitviewReviewed = true }, row_groups(s, 1))
    eq({ GitviewStatusStaged = true }, row_groups(s, 2))
    -- one changed since is to be read again, and not faded
    repo.write('a.lua', { 'return 8' })
    refresh(s)
    eq({ GitviewStatusStaged = true }, row_groups(s, 1))
  end)
end)

test('review: a directory is faded once every file in it is checked', function()
  with_session(function(repo)
    repo.write('src/a.lua', { 'return 1' })
    repo.write('src/b.lua', { 'return 1' })
    repo.write('top.lua', { 'return 1' })
    repo.commit('first')
    repo.write('src/a.lua', { 'return 2' })
    repo.write('src/b.lua', { 'return 2' })
    repo.write('top.lua', { 'return 2' })
  end, function(s)
    review_worktree(s)
    press(s, '3Gx')
    eq({ GitviewDirectory = true }, row_groups(s, 2))
    -- the letters in front of a name, in a tree, fade with it
    eq({ GitviewReviewed = true }, row_groups(s, 3))
    press(s, '4Gx')
    eq({ GitviewReviewed = true }, row_groups(s, 2))
    eq({ GitviewDirectory = true }, row_groups(s, 1))
  end, { tree = true })
end)
