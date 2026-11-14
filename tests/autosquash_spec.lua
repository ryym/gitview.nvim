local autosquash = require('gitview.autosquash')
local list = require('gitview.ui.list')
local session = require('gitview.ui.session')
local helpers = dofile('tests/helpers.lua')

local test, eq = _G.test, _G.eq

--- @param s gitview.Session
local function settle(s)
  local done = vim.wait(5000, function()
    return not s.autosquash and not s.reading
  end)
  assert(done, 'the autosquash or the status read never ended')
end

--- Open a session against a fresh repository, run `fn`, then close it.
--- @param setup fun(repo: gitview.TestRepo)
--- @param fn fun(s: gitview.Session, repo: gitview.TestRepo)
local function with_session(setup, fn)
  helpers.with_repo(function(repo)
    setup(repo)
    local previous = vim.fn.getcwd()
    vim.cmd.lcd(repo.root)
    local s = session.open()
    local ok, err = pcall(function()
      assert(s, 'no session opened')
      settle(s)
      fn(s, repo)
      settle(s)
      vim.wait(5000, function()
        return not s.loading and not s.pending
      end)
    end)
    if s and vim.api.nvim_tabpage_is_valid(s.tab) then
      session.close(s)
    end
    vim.cmd.lcd(previous)
    if not ok then
      error(err, 0)
    end
  end)
end

--- What `fn` said through `vim.notify`, without the prefix, once the session
--- has settled after it: an autosquash says what came of it when it ends.
--- @param s gitview.Session
--- @param fn fun()
--- @return string[]
local function notified(s, fn)
  local notify = vim.notify
  local messages = {}
  vim.notify = function(msg)
    messages[#messages + 1] = (msg:gsub('^gitview: ', ''))
  end
  local ok, err = pcall(function()
    fn()
    settle(s)
  end)
  vim.notify = notify
  assert(ok, err)
  return messages
end

--- Press keys in a pane, so that the buffer-local mapping is what is tested.
--- @param win integer
--- @param keys string
local function press(win, keys)
  vim.api.nvim_set_current_win(win)
  vim.cmd.normal(vim.keycode(keys))
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

--- Put the cursor on the commit of the list with this subject.
--- @param s gitview.Session
--- @param subject string
local function goto_subject(s, subject)
  for i, c in ipairs(s.commits) do
    if c.subject == subject then
      goto_row(s, { kind = 'commit', index = i })
      return
    end
  end
  error('no commit ' .. subject)
end

--- @param repo gitview.TestRepo
--- @return string[] subjects of HEAD's history, newest first
local function subjects(repo)
  return vim.split(vim.trim(repo.git('log', '--format=%s')), '\n', { plain = true })
end

--- @param s gitview.Session
--- @return string? the subject of the commit selected
local function selected_subject(s)
  local t = s.selected
  return t and t.kind == 'commit' and s.commits[t.index].subject or nil
end

--- @param repo gitview.TestRepo
--- @param rev string
--- @return string
local function short(repo, rev)
  return vim.trim(repo.git('rev-parse', '--short', rev))
end

--- @param repo gitview.TestRepo
--- @param rev string
--- @return string
local function full(repo, rev)
  return vim.trim(repo.git('rev-parse', rev))
end

--- A fixup of the second of three commits, made last.
local function with_fixup(repo)
  repo.write('a.txt', { 'a' })
  repo.commit('first')
  repo.write('b.txt', { 'b' })
  repo.commit('second')
  repo.write('c.txt', { 'c' })
  repo.commit('third')
  repo.write('b.txt', { 'b fixed' })
  repo.commit('fixup! second')
end

test('autosquash: `A` folds the fixups from the commit under the cursor up to HEAD', function()
  with_session(with_fixup, function(s, repo)
    local was = short(repo, 'HEAD')
    goto_subject(s, 'second')
    local said = notified(s, function()
      press(s.commits_win, 'A')
    end)
    eq({ ('autosquashed (HEAD was %s)'):format(was) }, said)
    eq({ 'third', 'second', 'first' }, subjects(repo))
    eq({ 'b fixed' }, vim.fn.readfile(repo.root .. '/b.txt'))
    -- The list is the new one, with the rewritten commit selected, rather than
    -- the old one held open for the commit that went.
    assert(not s.commits_stale)
    eq('second', selected_subject(s))
    eq(full(repo, 'HEAD~1'), s.commits[s.selected.index].full_sha)
  end)
end)

test('autosquash: fixups of any commit in the range are folded, not only of the one chosen', function()
  with_session(with_fixup, function(s, repo)
    goto_subject(s, 'first')
    notified(s, function()
      press(s.commits_win, 'A')
    end)
    eq({ 'third', 'second', 'first' }, subjects(repo))
    -- Nothing before `first` was rewritten, so it is the same commit still.
    eq('first', selected_subject(s))
  end)
end)

test('autosquash: from the root commit, the whole history is rebased', function()
  with_session(function(repo)
    repo.write('a.txt', { 'a' })
    repo.commit('first')
    repo.write('b.txt', { 'b' })
    repo.commit('second')
    repo.write('a.txt', { 'a fixed' })
    repo.commit('fixup! first')
  end, function(s, repo)
    goto_subject(s, 'first')
    notified(s, function()
      press(s.commits_win, 'A')
    end)
    eq({ 'second', 'first' }, subjects(repo))
    eq('first', selected_subject(s))
    eq(full(repo, 'HEAD~1'), s.commits[s.selected.index].full_sha)
  end)
end)

test('autosquash: says so when there is nothing to fold', function()
  with_session(function(repo)
    repo.write('a.txt', { 'a' })
    repo.commit('first')
    repo.write('b.txt', { 'b' })
    repo.commit('second')
  end, function(s, repo)
    local head = full(repo, 'HEAD')
    goto_subject(s, 'first')
    local said = notified(s, function()
      press(s.commits_win, 'A')
    end)
    eq({ 'nothing to squash' }, said)
    eq(head, full(repo, 'HEAD'))
  end)
end)

test('autosquash: a dirty working tree is left to git to refuse', function()
  with_session(function(repo)
    with_fixup(repo)
    repo.write('a.txt', { 'dirty' })
  end, function(s, repo)
    local head = full(repo, 'HEAD')
    goto_subject(s, 'second')
    local said = notified(s, function()
      press(s.commits_win, 'A')
    end)
    eq(1, #said)
    assert(said[1]:find('^git rebase %-%-autosquash failed'), said[1])
    eq(head, full(repo, 'HEAD'))
    eq({ 'dirty' }, vim.fn.readfile(repo.root .. '/a.txt'))
  end)
end)

-- A fixup of `second` folds in cleanly, rewriting it, and a fixup of `third`
-- then conflicts with `fourth`, which it was made on top of and now comes after
-- it.
local function stopping(repo)
  repo.write('a.txt', { 'a' })
  repo.commit('first')
  repo.write('b.txt', { 'b' })
  repo.commit('second')
  repo.write('c.txt', { '1', '2' })
  repo.commit('third')
  repo.write('c.txt', { '1x', '2' })
  repo.commit('fourth')
  repo.write('b.txt', { 'b fixed' })
  repo.commit('fixup! second')
  repo.write('c.txt', { '1x', '2x' })
  repo.commit('fixup! third')
end

test('autosquash: a conflict is reported, and the rebase left where it stopped', function()
  with_session(stopping, function(s, repo)
    local old_second = full(repo, 'HEAD~4')
    goto_subject(s, 'second')
    local said = notified(s, function()
      press(s.commits_win, 'A')
    end)
    eq(1, #said)
    -- git's own message, which names where it stopped, without the progress
    -- drawn before it.
    assert(said[1]:find('\nerror: could not apply %x+%.%.%. fixup! third\n'), said[1])
    assert(vim.uv.fs_stat(repo.root .. '/.git/rebase-merge'), 'the rebase was aborted')
    -- The stopped state is shown, with the rewritten `second` selected.
    assert(not s.commits_stale)
    eq('second', selected_subject(s))
    local now = s.commits[s.selected.index].full_sha
    assert(now ~= old_second, 'second was not rewritten')
    eq(full(repo, 'HEAD~1'), now)
    repo.git('rebase', '--abort')
  end)
end)

test('autosquash: the selection stays where the user went meanwhile', function()
  with_session(function(repo)
    with_fixup(repo)
    repo.write('untracked.txt', { 'u' })
  end, function(s, repo)
    goto_subject(s, 'second')
    notified(s, function()
      press(s.commits_win, 'A')
      -- Still running: the rebase does not block.
      assert(s.autosquash)
      local row = assert(list.row_of(s.files_buf, { kind = 'file', index = 1 }))
      vim.api.nvim_set_current_win(s.files_win)
      vim.api.nvim_win_set_cursor(s.files_win, { row, 0 })
      session.follow_cursor(s, s.files_win)
    end)
    eq({ 'third', 'second', 'first' }, subjects(repo))
    eq('file', s.selected.kind)
  end)
end)

test('autosquash: nothing is read or staged while it runs', function()
  with_session(function(repo)
    with_fixup(repo)
    repo.write('untracked.txt', { 'u' })
  end, function(s)
    local before = vim.api.nvim_buf_get_lines(s.commits_buf, 0, -1, false)
    goto_subject(s, 'second')
    local said = notified(s, function()
      press(s.commits_win, 'A')
      press(s.commits_win, 'R')
      press(s.commits_win, 'A')
      eq(before, vim.api.nvim_buf_get_lines(s.commits_buf, 0, -1, false))
      press(s.files_win, 's')
    end)
    eq({
      'an autosquash is running; the repository is read again once it ends',
      'an autosquash is running; try again once it ends',
      'an autosquash is running; try again once it ends',
    }, vim.list_slice(said, 1, 3))
  end)
end)

test('autosquash: refuses where it has no commit to start from', function()
  with_session(function(repo)
    with_fixup(repo)
    repo.write('untracked.txt', { 'u' })
  end, function(s)
    local said = {}
    said[#said + 1] = notified(s, function()
      goto_row(s, { kind = 'worktree', index = 1 })
      press(s.commits_win, 'A')
    end)[1]
    said[#said + 1] = notified(s, function()
      press(s.files_win, 'A')
    end)[1]
    said[#said + 1] = notified(s, function()
      press(s.files_win, 'VA')
    end)[1]
    said[#said + 1] = notified(s, function()
      goto_subject(s, 'second')
      press(s.commits_win, 'VkA')
    end)[1]
    eq('n', vim.fn.mode())
    said[#said + 1] = notified(s, function()
      goto_subject(s, 'third')
      press(s.commits_win, 'm')
      goto_subject(s, 'second')
      press(s.commits_win, 'A')
    end)[1]
    eq({
      'an autosquash starts from a commit',
      'an autosquash starts from a commit in the commits window',
      'an autosquash starts from a commit in the commits window',
      'an autosquash starts from one commit, not a selection',
      'clear the range first',
    }, said)
  end)
end)

test('autosquash: waits for a read of the status under way, which may hold the index lock', function()
  with_session(with_fixup, function(s, repo)
    local head = full(repo, 'HEAD')
    goto_subject(s, 'second')
    local said = notified(s, function()
      session.refresh(s)
      assert(s.reading)
      press(s.commits_win, 'A')
    end)
    eq({ 'the status is being read; try again in a moment' }, said)
    eq(head, full(repo, 'HEAD'))
  end)
end)

--- @param cwd string
--- @return gitview.Autosquashed
local function run_in(cwd, rev, ends)
  local done, res = false, nil
  require('gitview.git').async(function()
    return autosquash.run(rev, ends or {}, cwd)
  end, function(r)
    done, res = true, r
  end)
  assert(vim.wait(5000, function()
    return done
  end))
  return assert(res)
end

test('autosquash: refuses a commit not in the history of HEAD', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'a' })
    repo.commit('first')
    repo.git('checkout', '-q', '-b', 'side')
    repo.write('b.txt', { 'b' })
    repo.commit('on side')
    repo.git('checkout', '-q', '-')
    local res = run_in(repo.root, full(repo, 'side'))
    eq('the commit is not in the history of HEAD', res.refused)
  end)
end)

test('autosquash: refuses a range with a merge', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'a' })
    repo.commit('first')
    repo.git('checkout', '-q', '-b', 'side')
    repo.write('b.txt', { 'b' })
    repo.commit('on side')
    repo.git('checkout', '-q', '-')
    repo.write('c.txt', { 'c' })
    repo.commit('on main')
    repo.git('merge', '-q', '--no-ff', 'side', '-m', 'merge side')
    local res = run_in(repo.root, full(repo, 'HEAD~1'))
    eq(('%s is a merge'):format(short(repo, 'HEAD')), res.refused)
  end)
end)

test('autosquash: refuses a range with a squash!', function()
  helpers.with_repo(function(repo)
    with_fixup(repo)
    repo.write('c.txt', { 'c squashed' })
    repo.commit('squash! third')
    local res = run_in(repo.root, full(repo, 'HEAD~3'))
    assert(res.refused and res.refused:find('is a squash!', 1, true), res.refused)
  end)
end)

test('autosquash: refuses to rewrite an end of a review, but not the one it starts on', function()
  helpers.with_repo(function(repo)
    with_fixup(repo)
    local first, second = full(repo, 'HEAD~3'), full(repo, 'HEAD~2')
    eq('it would rewrite an end of the review', run_in(repo.root, second, { second }).refused)
    eq('it would rewrite an end of the review', run_in(repo.root, second, { 'HEAD~1' }).refused)
    -- The empty tree, which a review from the root starts at, is no commit.
    local empty = vim.trim(repo.git('hash-object', '-t', 'tree', '/dev/null'))
    local res = run_in(repo.root, second, { first, empty })
    eq(nil, res.refused)
    eq(true, res.moved)
  end)
end)

test('autosquash: runs in a review that ends at the working tree, and follows in its list', function()
  with_session(with_fixup, function(s, repo)
    session.review_refs('HEAD~3')
    settle(s)
    eq('review', s.listing)
    goto_subject(s, 'second')
    notified(s, function()
      press(s.commits_win, 'A')
    end)
    eq({ 'third', 'second', 'first' }, subjects(repo))
    eq('review', s.listing)
    eq({ 'third', 'second' }, vim.tbl_map(function(c)
      return c.subject
    end, s.commits))
    eq('second', selected_subject(s))
  end)
end)

test('autosquash: refuses in a review that ends at a commit', function()
  with_session(with_fixup, function(s, repo)
    local head = full(repo, 'HEAD')
    session.review_refs('HEAD~3', 'HEAD')
    settle(s)
    goto_subject(s, 'second')
    local said = notified(s, function()
      press(s.commits_win, 'A')
    end)
    eq({ 'not autosquashed: it would rewrite an end of the review' }, said)
    eq(head, full(repo, 'HEAD'))
  end)
end)
