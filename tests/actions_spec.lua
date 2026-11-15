--- The actions called directly rather than through the keys mapped to them,
--- which the session and review specs press. What is tested here is what only
--- a direct call shows: what they return, and where they refuse to act.
local actions = require('gitview.actions')
local list = require('gitview.ui.list')
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

--- Two commits and an uncommitted edit.
local function history(repo)
  repo.write('a.lua', { 'return 1' })
  repo.commit('first')
  repo.write('a.lua', { 'return 2' })
  repo.write('b.lua', { 'return 2' })
  repo.commit('second')
  repo.write('a.lua', { 'return 3' })
end

--- Put the commits pane's cursor on a commit, as moving there does.
--- @param s gitview.Session
--- @param index integer
local function goto_commit(s, index)
  vim.api.nvim_set_current_win(s.commits_win)
  local row = assert(list.row_of(s.commits_buf, { kind = 'commit', index = index }))
  vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
  session.follow_cursor(s, s.commits_win)
end

--- The arguments of the actions that need one.
local ARGS = { set_shown_changes = { shown = 'staged' }, set_ignore_whitespace = { ignore = true } }

test('actions: every one does nothing outside a session', function()
  for name, fn in pairs(actions) do
    eq(false, fn(ARGS[name]), name)
  end
end)

test('actions: the setters refuse what is no value of theirs', function()
  assert(not pcall(actions.set_shown_changes, { shown = 'all' }))
  assert(not pcall(actions.set_ignore_whitespace, { ignore = 'on' }))
end)

test('actions: an option not taken, missing or of another type is an error', function()
  local ok, err = pcall(actions.close, { foce = true })
  eq(false, ok)
  eq('gitview: close has no option "foce"', err)
  ok, err = pcall(actions.set_shown_changes, 'staged')
  eq(false, ok)
  eq('gitview: set_shown_changes takes a table of options, not "staged"', err)  ok, err = pcall(actions.close, { force = 'no' })
  eq(false, ok)
  eq('gitview: close takes force as a boolean, not "no"', err)
  ok, err = pcall(actions.set_ignore_whitespace, {})
  eq(false, ok)
  eq('gitview: set_ignore_whitespace takes ignore as a boolean, not nil', err)
end)

test('actions: a setter says nothing changed when it is set already', function()
  with_session(history, function(s)
    vim.api.nvim_set_current_win(s.files_win)
    eq(false, actions.set_shown_changes({ shown = 'both' }))
    eq(true, actions.set_shown_changes({ shown = 'staged' }))
    eq('staged', s.layer)
    eq(false, actions.set_ignore_whitespace({ ignore = false }))
    eq(true, actions.set_ignore_whitespace({ ignore = true }))
    eq(true, s.ignore_whitespace)
  end)
end)

test('actions: neither gitview nor its actions load the rest when required', function()
  local script = table.concat({
    "require('gitview').setup({})",
    "require('gitview.actions')",
    "io.write(tostring(package.loaded['gitview.ui.session'] ~= nil))",
  }, '; ')
  local out = vim
    .system({ 'nvim', '--headless', '--clean', '--cmd', 'set rtp+=.', '-l', '-' }, {
      stdin = script,
      text = true,
    })
    :wait()
  eq('false', out.stdout, out.stderr)
end)

--- What `:Gitview` with `args` said through `vim.notify`.
--- @param args string
--- @return string[]
local function run(args)
  local notify = vim.notify
  local messages = {}
  vim.notify = function(msg)
    messages[#messages + 1] = (msg:gsub('^gitview: ', ''))
  end
  local ok, err = pcall(vim.cmd, 'Gitview ' .. args)
  vim.notify = notify
  assert(ok, err)
  return messages
end

test(':Gitview run runs an action with its options', function()
  vim.cmd.runtime('plugin/gitview.lua')
  -- Loaded ahead, while the relative runtimepath of the suite can still find
  -- it: the session changes the directory.
  require('gitview.command')
  with_session(history, function(s)
    run('run cycle_shown_changes')
    eq('staged', s.layer)
    run('run set_shown_changes shown=both')
    eq('both', s.layer)
    run('run set_ignore_whitespace ignore=true')
    eq(true, s.ignore_whitespace)
    run('run set_ignore_whitespace ignore=false')
    eq(false, s.ignore_whitespace)
    local ok, err = pcall(vim.cmd, 'Gitview run set_shown_changes shown=all')
    eq(false, ok)
    assert(err:find('gitview: no such shown changes: "all"', 1, true), err)
    ok, err = pcall(vim.cmd, 'Gitview run set_shown_changes show=both')
    eq(false, ok)
    assert(err:find('gitview: set_shown_changes has no option "show"', 1, true), err)
    eq({ 'refresh takes no options' }, run('run refresh now'))
    eq({ 'not an option: =now' }, run('run refresh =now'))
    eq({ 'no such action: open' }, run('run open'))
    eq({ 'usage: :Gitview run <action> [<key>=<value> ...]' }, run('run'))
    eq({ 'no such subcommand: close' }, run('close'))
    eq({ 'usage: :Gitview review <base> [<new>]' }, run('review'))
    eq({ 'usage: :Gitview review <base> [<new>]' }, run('review a b c'))
    eq(false, actions.next_hunk())
    -- a range, as visual mode puts in front, is ignored
    vim.cmd('%Gitview run refresh')
    run('review HEAD~1 HEAD')
    eq('HEAD~1...HEAD', s.review.scope.label)
    -- a bare option is true
    run('run close force')
    assert(not vim.api.nvim_tabpage_is_valid(s.tab), 'not closed')
  end)
  eq({ 'no session in this tab page' }, run('run refresh'))
end)

test(':Gitview completes its subcommands and the actions', function()
  local command = require('gitview.command')
  eq({ 'review', 'run' }, command.complete('', 'Gitview '))
  eq({ 'run' }, command.complete('ru', 'Gitview ru'))
  local names = vim.tbl_keys(actions)
  table.sort(names)
  eq(names, command.complete('', 'Gitview run '))
  eq({ 'set_ignore_whitespace', 'set_shown_changes' }, command.complete('set_', 'Gitview run set_'))
  eq({}, command.complete('', 'Gitview run refresh '))
  eq({}, command.complete('', 'Gitview close '))
end)

test(':Gitview review completes ref names', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'a' })
    repo.commit('first')
    repo.git('branch', '-M', 'main')
    repo.git('branch', 'feature')
    repo.git('tag', 'v1')
    local previous = vim.fn.getcwd()
    vim.cmd.lcd(repo.root)
    local command = require('gitview.command')
    local ok, err = pcall(function()
      eq({ 'HEAD', 'feature', 'main', 'v1' }, command.complete('', 'Gitview review '))
      eq({ 'main' }, command.complete('m', 'Gitview review feature m'))
      eq({}, command.complete('', 'Gitview review main feature '))
      -- a buffer outside any repository leaves the current directory's, as
      -- the command itself does
      local outside = vim.fn.tempname()
      vim.fn.writefile({}, outside)
      vim.cmd.edit(outside)
      eq({ 'HEAD', 'feature', 'main', 'v1' }, command.complete('', 'Gitview review '))
      vim.cmd('bwipeout!')
      vim.fn.delete(outside)
    end)
    vim.cmd.lcd(previous)
    assert(ok, err)
  end)
end)

test('actions: a window that is no pane takes only the actions on the session', function()
  with_session(history, function(s)
    vim.cmd.new()
    local win = vim.api.nvim_get_current_win()
    eq(false, actions.focus_diff())
    eq(false, actions.stage())
    eq(false, actions.next_hunk())
    eq(true, actions.toggle_ignore_whitespace())
    eq(true, s.ignore_whitespace)
    eq(true, actions.refresh())
    settle(s)
    vim.api.nvim_win_close(win, true)
  end)
end)

test('actions: one that means nothing in the pane does nothing', function()
  with_session(history, function(s)
    vim.api.nvim_set_current_win(s.files_win)
    eq(false, actions.stage_hunk())
    eq(false, actions.look_into())
    vim.api.nvim_set_current_win(s.diff_win)
    eq(false, actions.focus_diff())
  end)
end)

test('actions: with nothing to undo they say they did nothing', function()
  with_session(history, function(s)
    vim.api.nvim_set_current_win(s.files_win)
    eq(false, actions.end_review())
    vim.api.nvim_set_current_win(s.commits_win)
    eq(false, actions.clear_range())
    eq(false, actions.back_out())
  end)
end)

test('actions: looking into a commit, and backing out', function()
  with_session(history, function(s)
    goto_commit(s, 1)
    eq(true, actions.look_into())
    assert(s.scope, 'not looking into the commit')
    -- already in, with nothing further to go into
    eq(false, actions.look_into())
    eq(true, actions.back_out())
    eq(nil, s.scope)
  end)
end)

test('actions: moving past the last change says it did nothing', function()
  with_session(history, function(s)
    session.select(s, 1)
    vim.api.nvim_set_current_win(s.diff_win)
    vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
    eq(true, actions.next_hunk())
    eq(false, actions.next_hunk())
  end)
end)

test('actions: close asks about a review part way through, unless forced', function()
  with_session(history, function(s)
    goto_commit(s, 1)
    eq(true, actions.start_review())
    vim.api.nvim_set_current_win(s.files_win)
    eq(true, actions.toggle_check())
    local confirm, asked = vim.fn.confirm, 0
    vim.fn.confirm = function()
      asked = asked + 1
      return 2
    end
    local ok, err = pcall(function()
      eq(true, actions.close())
      eq(1, asked)
      assert(vim.api.nvim_tabpage_is_valid(s.tab), 'closed in spite of the answer')
      eq(true, actions.close({ force = true }))
      eq(1, asked)
      assert(not vim.api.nvim_tabpage_is_valid(s.tab), 'not closed')
    end)
    vim.fn.confirm = confirm
    assert(ok, err)
  end)
end)
