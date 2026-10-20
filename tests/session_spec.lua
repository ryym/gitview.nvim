local list = require('gitview.ui.list')
local session = require('gitview.ui.session')
local helpers = dofile('tests/helpers.lua')

local test, eq = _G.test, _G.eq

--- Wait for the status being read in the background to be drawn.
--- @param s gitview.Session
local function settle(s)
  local done = vim.wait(5000, function()
    return not s.reading
  end)
  assert(done, 'the status was never read')
end

--- Open a session against a fresh repository, run `fn`, then close it.
---
--- `:lcd` into the repository is what makes the session find it, the same way
--- `:GitView` does when the current buffer has no file.
--- @param setup fun(repo: gitview.TestRepo)
--- @param fn fun(s: gitview.Session, repo: gitview.TestRepo)
--- @param opts? {unsettled?:boolean} `unsettled` to start `fn` while the status
---        is still being read, rather than once it has been drawn
local function with_session(setup, fn, opts)
  helpers.with_repo(function(repo)
    setup(repo)
    local previous = vim.fn.getcwd()
    vim.cmd.lcd(repo.root)
    local s = session.open()
    local ok, err = pcall(function()
      assert(s, 'no session opened')
      if not (opts and opts.unsettled) then
        settle(s)
      end
      fn(s, repo)
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

--- The files pane. The commits pane below it has tests of its own.
--- @param s gitview.Session
--- @return string[]
local function rows(s)
  return vim.api.nvim_buf_get_lines(s.files_buf, 0, -1, false)
end

--- The commits pane, which holds the commit list or, inside one, its files.
--- @param s gitview.Session
--- @return string[]
local function commit_rows(s)
  return vim.api.nvim_buf_get_lines(s.commits_buf, 0, -1, false)
end

--- Which file is selected, for the tests that only care about that.
--- @param s gitview.Session
--- @return integer?
local function selected(s)
  return s.selected and s.selected.index or nil
end

local function base(repo)
  repo.write('kept.txt', { 'same' })
  repo.write('edit.txt', { 'one' })
  repo.commit('init')
  repo.write('edit.txt', { 'two' })
  repo.write('loose.txt', { 'new' })
end

test('session: lists the repository it was opened in', function()
  with_session(base, function(s)
    eq({ 'edit.txt', 'loose.txt' }, rows(s))
    eq(s.root, list.state_of(s.files_buf).root)
  end)
end)

test('session: is registered against its own tab page', function()
  with_session(base, function(s)
    eq(s, session.sessions[s.tab])
    eq(s, session.current())
  end)
end)

test('session: names its buffers for the tab page label', function()
  with_session(base, function(s)
    eq('GitView', vim.fn.bufname(s.files_buf))
    eq('GitView:commits', vim.fn.bufname(s.commits_buf))
    eq('GitView:diff', vim.fn.bufname(s.diff_buf))
  end)
end)

test('session: opening again from elsewhere goes to the open session', function()
  with_session(base, function(s, repo)
    local origin = s.origin
    vim.cmd.tabnew()
    local elsewhere = vim.api.nvim_get_current_tabpage()
    vim.cmd.lcd(repo.root)
    local again = session.open()
    eq(s, again)
    eq(s.tab, vim.api.nvim_get_current_tabpage())
    eq(1, vim.tbl_count(session.sessions))
    -- `gf` still goes where the session was first opened from
    eq(origin, s.origin)
    vim.api.nvim_set_current_tabpage(elsewhere)
    vim.cmd.tabclose()
  end)
end)

test('session: a session on another repository takes numbered buffer names', function()
  with_session(base, function()
    helpers.with_repo(function(other)
      vim.cmd.tabnew()
      local scratch = vim.api.nvim_get_current_tabpage()
      vim.cmd.lcd(other.root)
      local s = session.open()
      assert(s, 'no session opened')
      local names = {
        vim.fn.bufname(s.files_buf),
        vim.fn.bufname(s.commits_buf),
        vim.fn.bufname(s.diff_buf),
      }
      session.close(s)
      vim.api.nvim_set_current_tabpage(scratch)
      vim.cmd.tabclose()
      eq({ 'GitView (2)', 'GitView:commits (2)', 'GitView:diff (2)' }, names)
    end)
  end)
end)

test('session: refreshing picks up changes made since', function()
  with_session(base, function(s, repo)
    repo.git('add', 'loose.txt')
    repo.write('third.txt', { 'more' })
    session.refresh(s)
    settle(s)
    eq({ 'edit.txt', 'loose.txt', 'third.txt' }, rows(s))
    eq('A', s.entries[2].index_status)
  end)
end)

test('session: an automatic refresh picks up changes made since', function()
  with_session(base, function(s, repo)
    repo.write('third.txt', { 'more' })
    session.refresh(s, { auto = true })
    settle(s)
    eq({ 'edit.txt', 'loose.txt', 'third.txt' }, rows(s))
  end)
end)

-- `TabEnter` fires on every move between tab pages, so an automatic refresh has
-- to be cheap to trigger. What the user asks for is never held back.
test('session: an automatic refresh is throttled and a manual one is not', function()
  with_session(base, function(s, repo)
    session.refresh(s, { auto = true })
    settle(s)
    repo.write('third.txt', { 'more' })
    session.refresh(s, { auto = true })
    settle(s)
    eq({ 'edit.txt', 'loose.txt' }, rows(s))
    session.refresh(s)
    settle(s)
    eq({ 'edit.txt', 'loose.txt', 'third.txt' }, rows(s))
  end)
end)

-- A poll handle is not owned by the tab page it was started for, so a session
-- that forgot to give it up would go on stating the index of a repository nobody
-- is looking at, once for every tab page ever opened.
test('session: the index watcher is given up with the tab page', function()
  local closed
  with_session(base, function(s)
    closed = s
    assert(s.watcher, 'no index watcher was started')
    eq(false, s.watcher:is_closing())
  end)
  eq(nil, closed.watcher)
end)

-- A refresh that fails would otherwise say so on every trigger, which is noise
-- rather than news: the next trigger will come along regardless.
test('session: only a manual refresh reports a git failure', function()
  with_session(base, function(s)
    local status = require('gitview.status')
    local list_entries, notify = status.list, vim.notify
    local messages = {}
    status.list = function()
      return nil, { what = 'git diff', stderr = 'boom' }
    end
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
    local ok, err = pcall(function()
      session.refresh(s, { auto = true })
      settle(s)
      eq({}, messages)
      session.refresh(s)
      settle(s)
      eq(1, #messages)
      assert(messages[1]:find('boom', 1, true), messages[1])
    end)
    status.list, vim.notify = list_entries, notify
    assert(ok, err)
  end)
end)

-- A refresh usually shortens the file section, and the cursor must not be left
-- past the end of the buffer, nor on one of the rows that stand for nothing.
test('session: refreshing pulls the cursor back inside the list', function()
  with_session(base, function(s, repo)
    vim.api.nvim_win_set_cursor(s.files_win, { 2, 0 })
    repo.git('checkout', '--', 'edit.txt')
    vim.fn.delete(s.root .. '/loose.txt')
    session.refresh(s)
    settle(s)
    eq({ list.EMPTY_NOTICE }, rows(s))
    eq(1, vim.api.nvim_win_get_cursor(s.files_win)[1])
  end)
end)

test('session: a clean repository shows the notice and no entries', function()
  with_session(function(repo)
    repo.write('a.txt', { 'x' })
    repo.commit('init')
  end, function(s)
    eq({ list.EMPTY_NOTICE }, rows(s))
    eq({}, s.entries)
    eq(nil, list.entry_at(s.files_buf, 1))
  end)
end)

test('session: closing drops the session and its buffer', function()
  with_session(base, function(s)
    local buf, tab = s.files_buf, s.tab
    session.close(s)
    eq(nil, session.sessions[tab])
    eq(false, vim.api.nvim_buf_is_valid(buf))
  end)
end)

-- The view is what a step filling in its syntax checks before it writes to the
-- buffer, so one kept past the buffer would have the step write to a buffer
-- that is gone.
test('session: closing drops the view its diff buffer showed', function()
  with_session(base, function(s)
    local buf = s.diff_buf
    assert(require('gitview.diff.render').view_of(buf), 'no view drawn')
    session.close(s)
    eq(false, vim.api.nvim_buf_is_valid(buf))
    eq(nil, require('gitview.diff.render').view_of(buf))
  end)
end)

-- Closing the tab any other way has to clean up just the same, or the session
-- outlives what it was drawn in.
test('session: closing the tab directly drops the session', function()
  with_session(base, function(s)
    local tab = s.tab
    vim.cmd.tabclose()
    eq(nil, session.sessions[tab])
  end)
end)

--- Wait for the session to be dropped, which closing a pane does on the next
--- turn of the event loop.
--- @param s gitview.Session
local function wait_dropped(s)
  local done = vim.wait(1000, function()
    return session.sessions[s.tab] == nil
  end)
  assert(done, 'the session was never dropped')
end

test('session: closing a pane closes the session', function()
  for _, pane in ipairs({ 'files_win', 'commits_win', 'diff_win' }) do
    with_session(base, function(s)
      local tab = s.tab
      vim.api.nvim_win_close(s[pane], true)
      wait_dropped(s)
      eq(false, vim.api.nvim_tabpage_is_valid(tab))
      eq(false, vim.api.nvim_buf_is_valid(s.files_buf))
    end)
  end
end)

-- `M.close` would `:quit` there, which would take Neovim with it.
test('session: closing a pane in the only tab page leaves one window', function()
  with_session(base, function(s)
    vim.cmd.tabonly()
    vim.api.nvim_win_close(s.diff_win, true)
    wait_dropped(s)
    eq(1, #vim.api.nvim_list_wins())
    eq(false, vim.api.nvim_buf_is_valid(s.files_buf))
    eq(false, vim.api.nvim_buf_is_valid(s.commits_buf))
    local win = vim.api.nvim_get_current_win()
    eq(false, vim.api.nvim_get_option_value('winfixbuf', { win = win }))
    -- Somewhere for the harness's own close to go back to.
    vim.cmd.tabnew()
  end)
end)

test('session: a pane refuses to show another buffer', function()
  with_session(base, function(s)
    for _, win in ipairs({ s.files_win, s.commits_win, s.diff_win }) do
      vim.api.nvim_set_current_win(win)
      local ok, err = pcall(vim.cmd.enew)
      eq(false, ok)
      assert(err:find('E1513'), err)
    end
  end)
end)

-- The gutter and the winbar are drawn by `%!` expressions, so a typo in one of
-- them shows only when the window actually renders. Unit tests of the functions
-- themselves never reach that.
test('session: the window renders its gutter and winbar', function()
  with_session(base, function(s)
    local win = s.files_win
    local gutter = vim.api.nvim_eval_statusline(vim.wo[win].statuscolumn, {
      winid = win,
      use_statuscol_lnum = 1,
      highlights = true,
    })
    eq(' M ', gutter.str) -- edit.txt is modified in the working tree only
    local groups = {}
    for _, h in ipairs(gutter.highlights) do
      groups[#groups + 1] = h.group
    end
    eq({ 'GitViewStatusStaged', 'GitViewStatusUnstaged' }, groups)

    local bar =
      vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true })
    assert(bar.str:find('2 files', 1, true), 'winbar: ' .. bar.str)
    assert(bar.str:find(vim.fs.basename(s.root), 1, true), 'winbar: ' .. bar.str)
  end)
end)

test('session: the list buffer carries its keymaps', function()
  with_session(base, function(s)
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(s.files_buf, 'n')) do
      lhs[m.lhs] = true
    end
    for _, key in ipairs({ 'R', 'gf', 'q' }) do
      assert(lhs[key], 'no mapping for ' .. key)
    end
  end)
end)

--- @param s gitview.Session
--- @return string[]
local function diff_rows(s)
  return vim.api.nvim_buf_get_lines(s.diff_buf, 0, -1, false)
end

--- A repository with one file changed on both sides and one untracked.
local function two(repo)
  repo.write('a.lua', { 'return 1' })
  repo.commit('init')
  repo.write('a.lua', { 'return 2' })
  repo.git('add', 'a.lua')
  repo.write('a.lua', { 'return 3' })
  repo.write('b.lua', { 'return 9' })
end

test('session: opens showing the first entry', function()
  with_session(two, function(s)
    eq(1, selected(s))
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('return 3', 1, true), text)
    -- one diff carries both layers, which is the whole point of the model
    local stages = {}
    for _, l in ipairs(require('gitview.diff.render').view_of(s.diff_buf).lines) do
      if l.stage then
        stages[l.stage] = true
      end
    end
    assert(stages.staged and stages.unstaged, vim.inspect(stages))
  end)
end)

-- The diff pane is one buffer for the life of the session. Swapping a buffer
-- into the window on every cursor move is what this design exists to avoid.
test('session: selecting another file redraws the same buffer', function()
  with_session(two, function(s)
    local buf = s.diff_buf
    session.select(s, 2)
    eq(2, selected(s))
    eq(buf, s.diff_buf)
    eq(buf, vim.api.nvim_win_get_buf(s.diff_win))
    eq({ 'b.lua', 'return 9' }, diff_rows(s))
  end)
end)

test('session: moving the list cursor selects', function()
  with_session(two, function(s)
    vim.api.nvim_set_current_win(s.files_win)
    vim.api.nvim_win_set_cursor(s.files_win, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.files_buf })
    eq(2, selected(s))
    eq({ 'b.lua', 'return 9' }, diff_rows(s))
  end)
end)

test('session: selecting past either end stays on the last file', function()
  with_session(two, function(s)
    session.select(s, 99)
    eq(2, selected(s))
    eq(2, vim.api.nvim_win_get_cursor(s.files_win)[1])
    session.select(s, -5)
    eq(1, selected(s))
  end)
end)

test('session: a change with no lines says so instead of showing nothing', function()
  with_session(function(repo)
    repo.write('doc.md', { 'text' })
    repo.commit('init')
    repo.git('mv', 'doc.md', 'guide.md')
  end, function(s)
    eq({ 'doc.md -> guide.md   (no textual change)' }, diff_rows(s))
    eq(nil, require('gitview.diff.render').view_of(s.diff_buf))
  end)
end)

test('session: a binary file says so', function()
  with_session(function(repo)
    repo.write('a.txt', { 'x' })
    repo.commit('init')
    local f = assert(io.open(repo.root .. '/logo.png', 'wb'))
    f:write('PNG\0\1\2')
    f:close()
  end, function(s)
    eq({ 'logo.png   (binary file)' }, diff_rows(s))
  end)
end)

test('session: an empty repository says so in both panes', function()
  with_session(function(repo)
    repo.write('a.txt', { 'x' })
    repo.commit('init')
  end, function(s)
    eq({ list.EMPTY_NOTICE }, diff_rows(s))
    eq(nil, selected(s))
  end)
end)

-- The same file can differ after a refresh, so the diff is rebuilt whether or
-- not the selection moved.
test('session: refreshing rebuilds the diff of the selected file', function()
  with_session(two, function(s, repo)
    repo.write('a.lua', { 'return 4' })
    session.refresh(s)
    settle(s)
    eq(1, selected(s))
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('return 4', 1, true), text)
  end)
end)

test('session: the diff pane takes what the list leaves', function()
  with_session(two, function(s)
    assert(vim.api.nvim_win_get_width(s.diff_win) > 0, 'the diff pane has no width')
    eq(true, vim.wo[s.files_win].winfixwidth)
    -- the files pane takes what the commit list leaves
    eq(true, vim.wo[s.commits_win].winfixheight)
    eq(false, vim.wo[s.files_win].winfixheight)
  end)
end)

--- Resize the screen as a terminal would, which fires VimResized. Without a UI
--- the windows keep their sizes, but 'columns' takes the new value, which is
--- what the sidebar's width is reckoned from.
--- @param columns integer
local function resize(columns)
  vim.o.columns = columns
  vim.api.nvim_exec_autocmds('VimResized', {})
end

--- Run `fn` with the sidebar's shares changed, putting back the screen and the
--- config afterwards.
--- @param opts gitview.Config
--- @param fn fun(s: gitview.Session)
local function with_shares(opts, fn)
  local config = require('gitview.config')
  local values, columns = config.values, vim.o.columns
  config.set(opts)
  local ok, err = pcall(with_session, two, fn)
  config.values = values
  resize(columns)
  assert(ok, err)
end

--- @param s gitview.Session
--- @return integer
local function sidebar_height(s)
  return vim.api.nvim_win_get_height(s.files_win) + vim.api.nvim_win_get_height(s.commits_win)
end

test('session: the sidebar keeps its shares of a resized screen', function()
  with_shares({ list_ratio = 0.25, commit_ratio = 0.4 }, function(s)
    resize(200)
    eq(50, vim.api.nvim_win_get_width(s.files_win))
    eq(50, vim.api.nvim_win_get_width(s.commits_win))
    eq(math.floor(sidebar_height(s) * 0.4), vim.api.nvim_win_get_height(s.commits_win))
    resize(160)
    eq(40, vim.api.nvim_win_get_width(s.files_win))
  end)
end)

test('session: the sidebar keeps its least size on a small screen', function()
  with_shares({ list_ratio = 0.25, commit_ratio = 0.01 }, function(s)
    resize(80)
    eq(30, vim.api.nvim_win_get_width(s.files_win))
    eq(3, vim.api.nvim_win_get_height(s.commits_win))
  end)
end)

test('session: a resize in another tab page lays the sidebar out on return', function()
  with_shares({ list_ratio = 0.25 }, function(s)
    vim.cmd.tabnew()
    resize(200)
    eq(30, vim.api.nvim_win_get_width(s.files_win))
    vim.api.nvim_set_current_tabpage(s.tab)
    eq(50, vim.api.nvim_win_get_width(s.files_win))
  end)
end)

test('session: returning without a resize keeps a width set by hand', function()
  with_shares({ list_ratio = 0.25 }, function(s)
    vim.api.nvim_win_set_width(s.files_win, 40)
    vim.cmd.tabnew()
    vim.api.nvim_set_current_tabpage(s.tab)
    eq(40, vim.api.nvim_win_get_width(s.files_win))
  end)
end)

test('session: every buffer goes when the session closes', function()
  with_session(two, function(s)
    local bufs = { s.files_buf, s.commits_buf, s.diff_buf }
    session.close(s)
    for _, buf in ipairs(bufs) do
      eq(false, vim.api.nvim_buf_is_valid(buf))
    end
  end)
end)

-- Listing untracked files walks the whole working tree, which is what made a
-- large repository slow to open.
test('session: opens before the status is read, then fills it in', function()
  with_session(base, function(s)
    eq({ list.LOADING_NOTICE }, rows(s))
    eq({ list.LOADING_NOTICE }, diff_rows(s))
    eq(nil, selected(s))
    settle(s)
    eq({ 'edit.txt', 'loose.txt' }, rows(s))
    eq({ kind = 'file', index = 1 }, s.selected)
  end, { unsettled = true })
end)

test('session: moving to the commits while the status is read stays there', function()
  with_session(base, function(s)
    vim.api.nvim_set_current_win(s.commits_win)
    eq('commit', s.selected.kind)
    settle(s)
    eq(s.commits_win, vim.api.nvim_get_current_win())
    eq({ kind = 'commit', index = 1 }, s.selected)
  end, { unsettled = true })
end)

-- Whichever read finishes first, only what the latest one found is drawn: the
-- one it overtook started from an older repository.
test('session: a read overtaken by a later one is dropped', function()
  with_session(base, function(s)
    local git = require('gitview.git')
    local status = require('gitview.status')
    local list_entries = status.list
    local slow_done = false
    local calls = 0
    status.list = function(root)
      calls = calls + 1
      if calls == 1 then
        git.run({ 'sleep', '0.2' }, root)
        slow_done = true
        return { { path = 'slow.txt', index_status = '?', worktree_status = '?' } }
      end
      return list_entries(root)
    end
    local ok, err = pcall(function()
      session.refresh(s)
      session.refresh(s)
      vim.wait(5000, function()
        return slow_done and not s.reading
      end)
      -- One more turn of the loop, for the callback scheduled after the sleep.
      vim.wait(50)
      eq({ 'edit.txt', 'loose.txt' }, rows(s))
    end)
    status.list = list_entries
    assert(ok, err)
  end)
end)

test('session: a first read that fails says so in place of the files', function()
  local status = require('gitview.status')
  local list_entries, notify = status.list, vim.notify
  local messages = {}
  local ok, err = pcall(function()
    with_session(function(repo)
      base(repo)
      status.list = function()
        return nil, { what = 'git diff', stderr = 'boom' }
      end
      vim.notify = function(msg)
        messages[#messages + 1] = msg
      end
    end, function(s)
      eq({ list.UNREADABLE_NOTICE }, rows(s))
      eq({ list.UNREADABLE_NOTICE }, diff_rows(s))
      eq(1, #messages)
    end)
  end)
  status.list, vim.notify = list_entries, notify
  assert(ok, err)
end)

--- Press a key in one of the sidebar panes, so that the buffer-local mapping is
--- what is being tested rather than the function behind it.
--- @param s gitview.Session
--- @param key string
--- @param win integer? which pane; the files pane by default
local function press(s, key, win)
  vim.api.nvim_set_current_win(win or s.files_win)
  vim.cmd.normal(key)
  settle(s)
end

test('session: `s` stages the file under the cursor', function()
  with_session(base, function(s, repo)
    session.select(s, 1)
    press(s, 's')
    eq('M', s.entries[1].index_status)
    eq('M  edit.txt\n?? loose.txt\n', repo.git('status', '--short'))
  end)
end)

test('session: `u` unstages the file under the cursor', function()
  with_session(base, function(s, repo)
    repo.git('add', 'edit.txt')
    session.refresh(s)
    settle(s)
    session.select(s, 1)
    press(s, 'u')
    eq(' ', s.entries[1].index_status)
    eq('M', s.entries[1].worktree_status)
  end)
end)

-- Staging never removes a file from the list, and the list is ordered by path,
-- so the row the cursor is on goes on meaning the same file.
test('session: staging leaves the cursor on the same file', function()
  with_session(base, function(s)
    session.select(s, 2)
    press(s, 's')
    eq(2, selected(s))
    eq('loose.txt', s.entries[selected(s)].path)
  end)
end)

test('session: staging an untracked file adds it to the index', function()
  with_session(base, function(s, repo)
    session.select(s, 2)
    press(s, 's')
    eq('A', s.entries[2].index_status)
    eq(' ', s.entries[2].worktree_status)
    eq('loose.txt\n', repo.git('diff', '--cached', '--name-only'))
  end)
end)

test('session: `u` before the first commit takes the file out of the index', function()
  with_session(function(repo)
    repo.write('a.txt', { 'one' })
    repo.git('add', '-A')
  end, function(s, repo)
    eq(false, s.has_head)
    session.select(s, 1)
    press(s, 'u')
    eq('?? a.txt\n', repo.git('status', '--short'))
  end)
end)

-- The first commit can be made while a session is open, so which command
-- unstages is not settled once at `open`.
test('session: a refresh notices that the repository gained a HEAD', function()
  with_session(function(repo)
    repo.write('a.txt', { 'one' })
    repo.git('add', '-A')
  end, function(s, repo)
    eq(false, s.has_head)
    repo.git('commit', '-qm', 'init')
    repo.write('a.txt', { 'two' })
    session.refresh(s)
    settle(s)
    eq(true, s.has_head)
  end)
end)

-- Until the status is re-read, the panes show the index as it was before the
-- first `s`; staging lines from them would write that back over it.
test('session: staging waits for the status it changed to be re-read', function()
  with_session(base, function(s, repo)
    session.select(s, 1)
    vim.api.nvim_set_current_win(s.files_win)
    vim.cmd.normal('s')
    eq(true, s.outdated)
    local notify = vim.notify
    local messages = {}
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
    local ok, err = pcall(function()
      vim.cmd.normal('u')
    end)
    vim.notify = notify
    assert(ok, err)
    eq(1, #messages)
    assert(messages[1]:find('re-read', 1, true), messages[1])
    settle(s)
    eq(nil, s.outdated)
    eq('M  edit.txt\n?? loose.txt\n', repo.git('status', '--short'))
  end)
end)

test('session: staging a file with nothing unstaged changes nothing', function()
  with_session(base, function(s, repo)
    repo.git('add', 'edit.txt')
    session.refresh(s)
    settle(s)
    session.select(s, 1)
    press(s, 's')
    eq('M  edit.txt\n?? loose.txt\n', repo.git('status', '--short'))
  end)
end)

--- Press a key in the diff pane, where `s` and `u` work on lines rather than on
--- the whole file. Mappings are applied, so the mapping is what is tested.
--- @param s gitview.Session
--- @param keys string
local function press_diff(s, keys)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.cmd.normal(keys)
  settle(s)
end

--- The diff row a changed line of this text is drawn on.
--- @param s gitview.Session
--- @param text string
--- @return integer
local function changed_row(s, text)
  local view = assert(require('gitview.diff.render').view_of(s.diff_buf), 'no view drawn')
  for i, l in ipairs(view.lines) do
    if l.text == text and l.stage then
      return i
    end
  end
  error('no changed row reading ' .. text)
end

--- @param s gitview.Session
--- @param row integer
local function put_cursor(s, row)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
end

test('session: `]f` in the diff moves the list and leaves the focus in the diff', function()
  with_session(two, function(s)
    press_diff(s, ']f')
    eq(2, selected(s))
    eq(2, vim.api.nvim_win_get_cursor(s.files_win)[1])
    eq({ 'b.lua', 'return 9' }, diff_rows(s))
    eq(s.diff_win, vim.api.nvim_get_current_win())
    press_diff(s, '[f')
    eq(1, selected(s))
    eq(s.diff_win, vim.api.nvim_get_current_win())
  end)
end)

local function partial(repo)
  repo.write('f.txt', { 'one', 'two', 'three', 'four', 'five' })
  repo.commit('init')
  repo.write('f.txt', { 'one', 'TWO', 'three', 'four', 'five', 'six' })
end

test('session: `s` in the diff stages the line under the cursor', function()
  with_session(partial, function(s, repo)
    put_cursor(s, changed_row(s, 'six'))
    press_diff(s, 's')
    eq('one\ntwo\nthree\nfour\nfive\nsix\n', repo.git('show', ':f.txt'))
    eq('MM f.txt\n', repo.git('status', '--short'))
  end)
end)

test('session: `S` in the diff stages the whole change the cursor is in', function()
  with_session(partial, function(s, repo)
    put_cursor(s, changed_row(s, 'TWO'))
    press_diff(s, 'S')
    -- Both rows of the change go, not only the added one.
    eq('one\nTWO\nthree\nfour\nfive\n', repo.git('show', ':f.txt'))
  end)
end)

test('session: a visual selection stages every row it covers', function()
  with_session(partial, function(s, repo)
    press_diff(s, 'ggVGs')
    eq('', repo.git('diff'))
    eq('M  f.txt\n', repo.git('status', '--short'))
  end)
end)

test('session: `u` in the diff unstages the line under the cursor', function()
  with_session(function(repo)
    repo.write('f.txt', { 'one', 'two' })
    repo.commit('init')
    repo.write('f.txt', { 'one', 'two', 'three' })
    repo.git('add', 'f.txt')
  end, function(s, repo)
    put_cursor(s, changed_row(s, 'three'))
    press_diff(s, 'u')
    eq('', repo.git('diff', '--cached'))
    eq(' M f.txt\n', repo.git('status', '--short'))
  end)
end)

test('session: staging in the diff redraws the pane as staged', function()
  with_session(partial, function(s)
    put_cursor(s, changed_row(s, 'six'))
    press_diff(s, 's')
    local view = require('gitview.diff.render').view_of(s.diff_buf)
    eq('staged', view.lines[changed_row(s, 'six')].stage)
  end)
end)

--- Twenty lines with the second and the nineteenth changed, which leaves a run
--- of unchanged lines folded between the two changes.
--- @param extra table<integer, string>? more lines to change
--- @return string[]
local function spread_lines(extra)
  local lines = {}
  for i = 1, 20 do
    lines[i] = 'line ' .. i
  end
  lines[2], lines[19] = 'TWO', 'NINETEEN'
  for i, text in pairs(extra or {}) do
    lines[i] = text
  end
  return lines
end

--- Two files changed alike, so that each folds the same rows.
local function spread(repo)
  local lines = spread_lines({ [2] = 'line 2', [19] = 'line 19' })
  repo.write('f.txt', lines)
  repo.write('g.txt', lines)
  repo.commit('init')
  repo.write('f.txt', spread_lines())
  repo.write('g.txt', spread_lines())
end

--- The diff row a folded line of this text is drawn on.
--- @param s gitview.Session
--- @param text string
--- @return integer
local function folded_row(s, text)
  local view = assert(require('gitview.diff.render').view_of(s.diff_buf), 'no view drawn')
  for i, l in ipairs(view.lines) do
    if l.folded and l.text == text then
      return i
    end
  end
  error('no folded row reading ' .. text)
end

--- @param s gitview.Session
--- @param text string
--- @return boolean
local function fold_open(s, text)
  local row = folded_row(s, text)
  return vim.api.nvim_win_call(s.diff_win, function()
    return vim.fn.foldclosed(row) == -1
  end)
end

--- @param s gitview.Session
--- @param text string
local function open_fold(s, text)
  put_cursor(s, folded_row(s, text))
  vim.api.nvim_win_call(s.diff_win, function()
    vim.cmd('normal! zo')
  end)
end

-- Replacing the lines under an open fold closes it when it gets shorter, so an
-- opened run is carried over explicitly. Working down a diff while it is being
-- edited would otherwise keep closing what the reader opened.
test('session: an opened run stays open while the same file is redrawn', function()
  with_session(spread, function(s, repo)
    eq(false, fold_open(s, 'line 10'))
    open_fold(s, 'line 10')
    eq(true, fold_open(s, 'line 10'))

    put_cursor(s, changed_row(s, 'TWO'))
    press_diff(s, 's')
    eq(true, fold_open(s, 'line 10'))

    -- a change further down shortens the run
    repo.write('f.txt', spread_lines({ [12] = 'TWELVE' }))
    session.refresh(s)
    settle(s)
    eq(true, fold_open(s, 'line 7'))
  end)
end)

-- The same rows are folded in the next file, and a fold replaced by one at
-- least as long stays open unless it is closed explicitly.
test('session: an opened run is closed again in another file', function()
  with_session(spread, function(s)
    open_fold(s, 'line 10')
    session.select(s, 2)
    eq(false, fold_open(s, 'line 10'))
    session.select(s, 1)
    eq(false, fold_open(s, 'line 10'))
  end)
end)

--- The rows of the closed fold over `row` in the diff pane.
--- @param s gitview.Session
--- @param row integer
--- @return integer first
--- @return integer last
local function closed_fold_at(s, row)
  local range = vim.api.nvim_win_call(s.diff_win, function()
    return { vim.fn.foldclosed(row), vim.fn.foldclosedend(row) }
  end)
  return range[1], range[2]
end

-- Neovim leaves the cursor on a fold's first row once it is open, which for a
-- file's first fold is the top of the file, far from the change below it.
test("session: opening a file's first fold leaves the cursor above the change", function()
  with_session(spread, function(s, repo)
    repo.write('f.txt', spread_lines({ [2] = 'line 2' }))
    session.refresh(s)
    settle(s)
    local first, last = closed_fold_at(s, folded_row(s, 'line 1'))
    assert(last > first, 'expected the fixture to fold the top of the file')
    put_cursor(s, first)
    local screen_row = vim.api.nvim_win_call(s.diff_win, vim.fn.winline)
    press_diff(s, 'zo')
    eq(true, fold_open(s, 'line 1'))
    eq(last, vim.api.nvim_win_get_cursor(s.diff_win)[1])
    eq(screen_row, vim.api.nvim_win_call(s.diff_win, vim.fn.winline))
  end)
end)

test('session: opening any other fold leaves the cursor where Neovim does', function()
  with_session(spread, function(s)
    local first, last = closed_fold_at(s, folded_row(s, 'line 10'))
    assert(last > first, 'expected the fixture to fold between the changes')
    put_cursor(s, first)
    press_diff(s, 'zo')
    eq(true, fold_open(s, 'line 10'))
    eq(first, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  end)
end)

test('session: a row with nothing to stage leaves the index alone', function()
  with_session(partial, function(s, repo)
    -- `three` is unchanged in all three versions, so it is a context row.
    local view = require('gitview.diff.render').view_of(s.diff_buf)
    local row
    for i, l in ipairs(view.lines) do
      if l.text == 'three' then
        row = i
      end
    end
    put_cursor(s, assert(row))
    press_diff(s, 's')
    eq(' M f.txt\n', repo.git('status', '--short'))
  end)
end)

test('session: staging part of an untracked file from the diff', function()
  with_session(base, function(s, repo)
    session.select(s, 2)
    put_cursor(s, changed_row(s, 'new'))
    press_diff(s, 's')
    eq('A  loose.txt\n', repo.git('status', '--short'):match('(A  loose.txt\n)'))
  end)
end)

--- Leave the repository mid-merge with one conflicted file and one clean change.
--- @param repo gitview.TestRepo
local function mid_merge(repo)
  repo.write('fight.txt', { 'base' })
  repo.commit('init')
  repo.git('checkout', '-q', '-b', 'other')
  repo.write('fight.txt', { 'theirs' })
  repo.commit('theirs')
  repo.git('checkout', '-q', '-')
  repo.write('fight.txt', { 'ours' })
  repo.commit('ours')
  -- The merge is meant to fail, so its exit code is not checked. The style is
  -- fixed so that a `diff3` in the user's config adds no base to the markers.
  vim
    .system(
      { 'git', '-c', 'merge.conflictStyle=merge', 'merge', 'other' },
      { cwd = repo.root, text = true }
    )
    :wait()
end

-- Writing a stage-0 entry over a conflict's merge stages discards them and git
-- reports no error, so the row-level keys have to refuse outright.
test('session: `s` in the diff leaves a conflict alone and says why', function()
  with_session(mid_merge, function(s, repo)
    local before = repo.git('ls-files', '-u')
    assert(before ~= '', 'the merge stages should be there to begin with')
    local notify, messages = vim.notify, {}
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
    local ok, err = pcall(function()
      vim.api.nvim_set_current_win(s.diff_win)
      -- on a row of the conflict, which the view now draws
      vim.api.nvim_win_set_cursor(s.diff_win, { 3, 0 })
      for _, key in ipairs({ 's', 'u', 'S', 'U' }) do
        vim.cmd.normal(key)
      end
    end)
    vim.notify = notify
    assert(ok, err)
    eq(before, repo.git('ls-files', '-u'))
    eq('UU fight.txt\n', repo.git('status', '--short'))
    eq(4, #messages)
    for _, m in ipairs(messages) do
      assert(m:find('fight.txt has an unresolved conflict', 1, true), m)
    end
  end)
end)

test('session: `u` in the list refuses a conflict, `s` resolves it', function()
  with_session(mid_merge, function(s, repo)
    session.select(s, 1)
    press(s, 'u')
    eq('UU fight.txt\n', repo.git('status', '--short'))
    press(s, 's')
    eq('M  fight.txt\n', repo.git('status', '--short'))
    eq('', repo.git('ls-files', '-u'))
  end)
end)

--- A repository with a history worth listing: two commits, and one uncommitted
--- change so that the file section is not empty either.
local function history(repo)
  repo.write('a.lua', { 'return 1' })
  repo.commit('first')
  repo.write('a.lua', { 'return 2' })
  repo.write('added.lua', { 'return 9' })
  repo.commit('second')
  repo.write('a.lua', { 'return 3' })
end

--- Put the cursor on a commit row and draw it. `sync_selection` reads a commit
--- in the background, behind a placeholder; the tests assert what is drawn, not
--- when, except those that use `land_on`.
--- @param s gitview.Session
--- @param index integer into the commits
local function show_commit(s, index)
  local row = assert(list.row_of(s.commits_buf, { kind = 'commit', index = index }))
  vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
  s.selected = { kind = 'commit', index = index }
  session.show_selected(s)
end

test('session: lists the recent commits in a pane of their own', function()
  with_session(history, function(s)
    eq({ 'second', 'first' }, vim.tbl_map(function(c)
      return c.subject
    end, s.commits))
    -- however long the file list grows, it does not push the history down
    eq({ 'a.lua' }, rows(s))
    local shas = vim.tbl_map(function(c)
      return c.sha
    end, s.commits)
    -- the working tree heads the list, as the newest end a range can have
    local zeros = ('0'):rep(#shas[1])
    eq({ zeros .. ' uncommitted changes', shas[1] .. ' second', shas[2] .. ' first' }, commit_rows(s))
    eq({ kind = 'worktree', index = 1 }, list.target_at(s.commits_buf, 1))
    eq({ kind = 'commit', index = 1 }, list.target_at(s.commits_buf, 2))
  end)
end)

-- Both panes are the same repository, so it is named once, and each says what
-- it is holding.
test('session: each pane says what it is showing', function()
  with_session(history, function(s)
    local function winbar(win)
      vim.g.statusline_winid = win
      return (list.winbar():gsub('%%#%w+#', ''))
    end
    eq(' test-repo   1 file', winbar(s.files_win))
    eq(' 2 commits', winbar(s.commits_win))
    show_commit(s, 1)
    session.enter(s)
    eq(' ' .. s.commits[1].sha .. ' second', winbar(s.commits_win))
  end)
end)

-- The cursors are independent, so moving between the panes has to be what tells
-- the diff which list the selection now comes from; neither cursor moves.
test('session: entering a pane selects from that pane', function()
  with_session(history, function(s)
    vim.api.nvim_set_current_win(s.commits_win)
    eq('worktree', s.selected.kind)
    vim.api.nvim_set_current_win(s.files_win)
    eq('file', s.selected.kind)
  end)
end)

--- A repository whose branch tracks `base`, one commit ahead of it.
--- @param repo gitview.TestRepo
local function ahead(repo)
  repo.write('a.txt', { 'one' })
  repo.commit('first')
  repo.git('branch', 'base')
  repo.git('branch', '--set-upstream-to=base')
  repo.write('a.txt', { 'two' })
  repo.commit('second')
end

--- The rows of the commits pane whose sha is faded as pushed, 0-based.
--- @param s gitview.Session
--- @return integer[]
local function pushed_rows(s)
  local ns = vim.api.nvim_create_namespace('gitview.ui.list.upstream')
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.commits_buf, ns, 0, -1, { details = true })) do
    if m[4].hl_group == 'GitViewCommitShaPushed' then
      out[#out + 1] = m[2]
    end
  end
  return out
end

test('session: knows which commits are pushed', function()
  with_session(ahead, function(s)
    eq({ [s.commits[1].full_sha] = true }, s.unpushed)
    eq(s.commits[2].full_sha, s.upstream.sha)
    -- Below the working-tree row and the unpushed commit.
    eq({ 2 }, pushed_rows(s))
  end)
end)

-- A push writes no index, so it is the upstream's ref that has to be watched
-- for one to be seen without `R`.
test('session: a push is seen without a refresh', function()
  with_session(ahead, function(s, repo)
    repo.git('branch', '-f', 'base', 'HEAD')
    local seen = vim.wait(5000, function()
      return s.unpushed and next(s.unpushed) == nil
    end)
    assert(seen, 'the push was never seen')
    eq(s.commits[1].full_sha, s.upstream.sha)
    eq({ 1, 2 }, pushed_rows(s))
  end)
end)

-- The ref to watch is the upstream's, which another branch, or the same one
-- set to track something else, has a different one of.
test('session: the upstream watched follows the branch', function()
  with_session(ahead, function(s, repo)
    eq('refs/heads/base', s.watched_ref)
    repo.git('branch', 'other', 'HEAD')
    repo.git('branch', '--set-upstream-to=other')
    session.refresh(s)
    settle(s)
    eq('refs/heads/other', s.watched_ref)
    repo.git('branch', '--unset-upstream')
    session.refresh(s)
    settle(s)
    eq(nil, s.watched_ref)
    eq(nil, s.upstream_watchers)
  end)
end)

-- `git push -u` sets what a branch tracks in the config, writing no index, and
-- it is how a new branch usually gets its first upstream.
test('session: an upstream set on the branch is seen without a refresh', function()
  with_session(function(repo)
    repo.write('a.txt', { 'one' })
    repo.commit('first')
    repo.git('branch', 'base')
  end, function(s, repo)
    eq(nil, s.upstream)
    repo.git('branch', '--set-upstream-to=base')
    local seen = vim.wait(5000, function()
      return s.upstream ~= nil
    end)
    assert(seen, 'the upstream was never seen')
    eq('refs/heads/base', s.watched_ref)
  end)
end)

test('session: the upstream watchers are given up with the tab page', function()
  local closed
  with_session(ahead, function(s)
    closed = s
    eq(2, #s.upstream_watchers)
    assert(s.config_watcher, 'no config watcher was started')
  end)
  eq(nil, closed.upstream_watchers)
  eq(nil, closed.config_watcher)
end)

-- A repository with no commit has no log to read, and `git log` fails there
-- rather than printing nothing.
test('session: a repository with no HEAD lists no commits', function()
  with_session(function(repo)
    repo.write('a.txt', { 'x' })
  end, function(s)
    eq({}, s.commits)
    eq(false, s.has_head)
  end)
end)

test('session: selecting a commit shows what it changed', function()
  with_session(history, function(s)
    show_commit(s, 1)
    local text = table.concat(diff_rows(s), '\n')
    -- both sides come from the object database, so the working tree's
    -- `return 3` must not appear
    assert(text:find('return 1', 1, true), text)
    assert(text:find('return 2', 1, true), text)
    assert(not text:find('return 3', 1, true), text)
    assert(text:find('added.lua', 1, true), text)
  end)
end)

-- The root commit adds every file it lists, so it never names the parent it
-- does not have.
test('session: the root commit shows its files as additions', function()
  with_session(history, function(s)
    show_commit(s, 2)
    local view = require('gitview.diff.render').view_of(s.diff_buf)
    assert(view, 'the root commit should have a view')
    for _, l in ipairs(view.lines) do
      if require('gitview.diff.lines').source_kinds[l.kind] then
        eq('add', l.kind)
      end
    end
  end)
end)

test('session: a commit view is not mixed', function()
  with_session(history, function(s)
    show_commit(s, 1)
    local view = require('gitview.diff.render').view_of(s.diff_buf)
    eq(nil, view.mixed)
  end)
end)

-- Nothing about a commit is stageable, and the index contents a partial stage
-- needs are never read for one.
test('session: staging is refused while a commit is selected', function()
  with_session(history, function(s, repo)
    show_commit(s, 1)
    -- Nothing was read for the index, so nothing can be written back to it.
    eq(nil, s.index_lines)
    local before = repo.git('status', '--short')
    press(s, 's', s.commits_win)
    press(s, 'u', s.commits_win)
    eq(before, repo.git('status', '--short'))
  end)
end)

-- Staging a file must not be confused by the commit section sitting below it.
test('session: the selection survives a refresh that changes the file count', function()
  with_session(history, function(s, repo)
    show_commit(s, 2)
    local sha = s.commits[2].sha
    repo.write('later.lua', { 'return 0' })
    session.refresh(s)
    settle(s)
    eq('commit', s.selected.kind)
    eq(sha, s.commits[s.selected.index].sha)
  end)
end)

test('session: looking into a commit lists the files it changed', function()
  with_session(history, function(s)
    show_commit(s, 1)
    session.enter(s)
    eq(s.commits[1].sha .. ' second', s.scope.label)
    eq({ 'a.lua', 'added.lua' }, vim.tbl_map(function(c)
      return c.path
    end, s.scope.changes))
    -- the header names the commit, and the files replace the whole list
    eq({ 'a.lua', 'added.lua' }, commit_rows(s))
    -- the first file is selected, so the pane shows it rather than nothing
    eq({ kind = 'commit_file', index = 1 }, s.selected)
  end)
end)

test('session: a file of a commit is shown by itself', function()
  with_session(history, function(s)
    show_commit(s, 1)
    session.enter(s)
    session.show_selected(s)
    local view = require('gitview.diff.render').view_of(s.diff_buf)
    eq(1, #view.files)
    eq('a.lua', view.files[1].label)
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('return 1', 1, true), text)
    assert(text:find('return 2', 1, true), text)
    -- the working tree's version is not one of the two being compared
    assert(not text:find('return 3', 1, true), text)
  end)
end)

--- Put an empty buffer in the current window and wipe the one it showed, so
--- that a file `gf` opened does not linger into the next test. Deleting it
--- outright would close the window, and with it a tab page it is alone in.
local function wipe_opened()
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd.enew()
  vim.api.nvim_buf_delete(buf, { force = true })
end

--- Press `gf` in one of the session's panes, and say where it landed: the file
--- relative to the repository, and the line the cursor is on.
--- @param s gitview.Session
--- @param win integer
--- @return string? path nil when the current buffer did not change
--- @return integer lnum
local function press_gf(s, win)
  vim.api.nvim_set_current_win(win)
  local before = vim.api.nvim_get_current_buf()
  vim.cmd.normal('gf')
  local buf = vim.api.nvim_get_current_buf()
  if buf == before then
    return nil, 0
  end
  local path = vim.fs.relpath(s.root, vim.api.nvim_buf_get_name(buf))
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  wipe_opened()
  return path, lnum
end

--- The diff row drawn for this text.
--- @param s gitview.Session
--- @param text string
--- @param kind string
--- @return integer
local function row_of_text(s, text, kind)
  local view = assert(require('gitview.diff.render').view_of(s.diff_buf), 'no view drawn')
  for i, l in ipairs(view.lines) do
    if l.text == text and l.kind == kind then
      return i
    end
  end
  error(('no %s row for %q'):format(kind, text))
end

test('session: `gf` opens the file in the tab page it was opened from', function()
  with_session(base, function(s)
    local origin = s.origin
    assert(origin ~= s.tab and vim.api.nvim_tabpage_is_valid(origin), 'no tab page to go back to')
    vim.api.nvim_win_set_cursor(s.files_win, { 2, 0 }) -- loose.txt
    vim.api.nvim_set_current_win(s.files_win)
    vim.cmd.normal('gf')
    eq(origin, vim.api.nvim_get_current_tabpage())
    eq(s.root .. '/loose.txt', vim.api.nvim_buf_get_name(0))
    wipe_opened()
    -- the session is still there to go back to
    assert(session.sessions[s.tab], 'the session should still be open')
  end)
end)

--- Four lines, of which the second is deleted and a fifth added.
local function edited(repo)
  repo.write('f.txt', { 'a', 'b', 'c', 'd' })
  repo.commit('init')
  repo.write('f.txt', { 'a', 'c', 'd', 'e' })
end

test('session: `gf` in the diff opens the file at the line under the cursor', function()
  with_session(edited, function(s)
    vim.api.nvim_win_set_cursor(s.diff_win, { row_of_text(s, 'e', 'add'), 0 })
    eq({ 'f.txt', 4 }, { press_gf(s, s.diff_win) })
    vim.api.nvim_set_current_tabpage(s.tab)
    vim.api.nvim_win_set_cursor(s.diff_win, { row_of_text(s, 'd', 'context'), 0 })
    eq({ 'f.txt', 3 }, { press_gf(s, s.diff_win) })
  end)
end)

-- A deleted line is in no version the working tree has; what stands where it
-- was is the line after the one above it.
test('session: `gf` on a deleted line opens the line now in its place', function()
  with_session(edited, function(s)
    vim.api.nvim_win_set_cursor(s.diff_win, { row_of_text(s, 'b', 'del'), 0 })
    eq({ 'f.txt', 2 }, { press_gf(s, s.diff_win) })
  end)
end)

test('session: `gf` on a file header opens the file at its top', function()
  with_session(edited, function(s)
    vim.api.nvim_win_set_cursor(s.diff_win, { row_of_text(s, 'f.txt', 'file'), 0 })
    eq({ 'f.txt', 1 }, { press_gf(s, s.diff_win) })
  end)
end)

test('session: `gf` opens a new tab page when its own has been closed', function()
  with_session(base, function(s)
    vim.cmd.tabnew()
    local gone = vim.api.nvim_get_current_tabpage()
    vim.cmd.tabclose()
    s.origin = gone
    vim.api.nvim_set_current_tabpage(s.tab)
    local before = #vim.api.nvim_list_tabpages()
    eq('edit.txt', (press_gf(s, s.files_win)))
    eq(before + 1, #vim.api.nvim_list_tabpages())
    -- it stands just before the session's, and is used from then on
    local tabs = vim.api.nvim_list_tabpages()
    local at = vim.fn.index(tabs, s.tab)
    eq(tabs[at], s.origin)
    vim.api.nvim_set_current_tabpage(s.origin)
    vim.cmd.tabclose()
  end)
end)

-- Choosing another window would make where the file lands hard to predict, so
-- the refusal is reported instead.
test('session: `gf` leaves a window pinned to its buffer alone', function()
  with_session(base, function(s)
    local win = vim.api.nvim_tabpage_get_win(s.origin)
    local buf = vim.api.nvim_win_get_buf(win)
    vim.wo[win].winfixbuf = true
    vim.api.nvim_set_current_win(s.files_win)
    vim.cmd.normal('gf')
    vim.wo[win].winfixbuf = false
    eq(s.origin, vim.api.nvim_get_current_tabpage())
    eq(buf, vim.api.nvim_win_get_buf(win))
  end)
end)

-- A staged deletion has no working copy to open, and `:edit` would make an
-- empty buffer for it as if the file were new.
test('session: `gf` on a file the working tree lacks opens nothing', function()
  with_session(function(repo)
    repo.write('gone.txt', { 'x' })
    repo.commit('init')
    repo.git('rm', '-q', 'gone.txt')
  end, function(s)
    eq(nil, (press_gf(s, s.files_win)))
    eq(s.tab, vim.api.nvim_get_current_tabpage())
  end)
end)

test('session: `gf` opens a file of a commit, at its line of the commit', function()
  with_session(history, function(s)
    show_commit(s, 1)
    vim.api.nvim_win_set_cursor(s.diff_win, { row_of_text(s, 'return 9', 'add'), 0 })
    eq({ 'added.lua', 1 }, { press_gf(s, s.diff_win) })
    vim.api.nvim_set_current_tabpage(s.tab)
    session.enter(s)
    vim.api.nvim_win_set_cursor(s.commits_win, { 2, 0 }) -- added.lua
    eq({ 'added.lua', 1 }, { press_gf(s, s.commits_win) })
  end)
end)

-- A commit is many files, and the row does not say which of them is meant.
test('session: `gf` on a commit row opens nothing', function()
  with_session(history, function(s)
    show_commit(s, 1)
    eq(nil, (press_gf(s, s.commits_win)))
    -- nor does a row of its header, which comes before any file
    vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
    eq(nil, (press_gf(s, s.diff_win)))
  end)
end)

--- Press `gy` in the diff over the rows from `first` to `last`, or on `first`
--- alone, and say what it copied into the `a` register.
--- @param s gitview.Session
--- @param first integer
--- @param last integer?
--- @return string
local function press_gy(s, first, last)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.fn.setreg('a', '')
  vim.api.nvim_win_set_cursor(s.diff_win, { first, 0 })
  if last then
    vim.cmd.normal(('V%dG"agy'):format(last))
  else
    vim.cmd.normal('"agy')
  end
  return vim.fn.getreg('a')
end

test('session: `gy` copies the file and line under the cursor', function()
  with_session(edited, function(s)
    eq('f.txt:4', press_gy(s, row_of_text(s, 'e', 'add')))
    eq('f.txt:3', press_gy(s, row_of_text(s, 'd', 'context')))
    -- a header stands for the whole file
    eq('f.txt', press_gy(s, row_of_text(s, 'f.txt', 'file')))
  end)
end)

test('session: `gy` copies the range of the lines selected', function()
  with_session(edited, function(s)
    eq('f.txt:1-4', press_gy(s, row_of_text(s, 'f.txt', 'file'), row_of_text(s, 'e', 'add')))
    eq('f.txt:3-4', press_gy(s, row_of_text(s, 'd', 'context'), row_of_text(s, 'e', 'add')))
  end)
end)

-- The deleted line counts as the one now in its place, so the range takes in
-- where it was rather than leaving it out.
test('session: `gy` over a deleted line and others copies the range they now have', function()
  with_session(edited, function(s)
    eq('f.txt:1-2', press_gy(s, row_of_text(s, 'a', 'context'), row_of_text(s, 'b', 'del')))
    eq('f.txt:2', press_gy(s, row_of_text(s, 'b', 'del'), row_of_text(s, 'c', 'context')))
  end)
end)

test('session: `gy` over a deletion at the end stays inside the file', function()
  with_session(function(repo)
    repo.write('f.txt', { 'a', 'b', 'c' })
    repo.commit('init')
    repo.write('f.txt', { 'a', 'X' })
  end, function(s)
    eq('f.txt:2', press_gy(s, row_of_text(s, 'X', 'add'), row_of_text(s, 'c', 'del')))
  end)
end)

test('session: `gy` over deleted lines alone copies where they were', function()
  with_session(function(repo)
    repo.write('f.txt', { 'a', 'b', 'c', 'd' })
    repo.commit('init')
    repo.write('f.txt', { 'a', 'd' })
  end, function(s)
    eq(
      'f.txt:2-3 (deleted from HEAD)',
      press_gy(s, row_of_text(s, 'b', 'del'), row_of_text(s, 'c', 'del'))
    )
  end)
end)

-- Staged, then removed from the working tree: HEAD never had the line, so its
-- place is the index's.
test('session: `gy` on a line only the index had copies its place there', function()
  with_session(function(repo)
    repo.write('f.txt', { 'a', 'b' })
    repo.commit('init')
    repo.write('f.txt', { 'a', 'x', 'b' })
    repo.git('add', 'f.txt')
    repo.write('f.txt', { 'a', 'b' })
  end, function(s)
    eq('f.txt:2 (deleted from the index)', press_gy(s, row_of_text(s, 'x', 'del')))
  end)
end)

test('session: `gy` in a commit names the commit', function()
  with_session(history, function(s)
    show_commit(s, 1)
    local commit = s.commits[1]
    eq(
      ('added.lua:1 (at %s)'):format(commit.sha),
      press_gy(s, row_of_text(s, 'return 9', 'add'))
    )
    eq(
      ('a.lua:1 (deleted from %s)'):format(commit.parents[1]),
      press_gy(s, row_of_text(s, 'return 1', 'del'))
    )
  end)
end)

test('session: `gy` over several files copies a line for each', function()
  with_session(history, function(s)
    show_commit(s, 1)
    local sha = s.commits[1].sha
    -- the commit's header above the first file belongs to none
    eq(
      ('a.lua:1 (at %s)\nadded.lua:1 (at %s)'):format(sha, sha),
      press_gy(s, 1, vim.api.nvim_buf_line_count(s.diff_buf))
    )
    eq('', press_gy(s, 1))
  end)
end)

test('session: backing out returns to the commit that was looked into', function()
  with_session(history, function(s)
    show_commit(s, 1)
    local sha = s.commits[1].sha
    session.enter(s)
    session.leave(s)
    eq(nil, s.scope)
    eq({ 'a.lua' }, rows(s))
    eq({ kind = 'commit', index = 1 }, s.selected)
    eq(sha, s.commits[s.selected.index].sha)
  end)
end)

test('session: backing out of nothing does nothing', function()
  with_session(history, function(s)
    session.select(s, 1)
    session.leave(s)
    eq(nil, s.scope)
    eq({ kind = 'file', index = 1 }, s.selected)
  end)
end)

-- A commit is immutable, so looking into one survives a refresh. What is
-- re-read is the state underneath, which is what backing out goes back to.
test('session: a refresh keeps the commit being looked into', function()
  with_session(history, function(s, repo)
    show_commit(s, 1)
    session.enter(s)
    repo.write('later.lua', { 'return 0' })
    session.refresh(s)
    settle(s)
    eq(s.commits[1].sha .. ' second', s.scope.label)
    eq({ kind = 'commit_file', index = 1 }, s.selected)
    session.leave(s)
    eq({ 'a.lua', 'later.lua' }, rows(s))
  end)
end)

test('session: staging is refused while a commit file is selected', function()
  with_session(history, function(s, repo)
    show_commit(s, 1)
    session.enter(s)
    local before = repo.git('status', '--short')
    press(s, 's', s.commits_win)
    press(s, 'u', s.commits_win)
    eq(before, repo.git('status', '--short'))
  end)
end)

--- A history whose diffs are long enough for a position in them to matter, and
--- an uncommitted change of the same size.
local function long_history(repo)
  local function numbered(word)
    local lines = {}
    for i = 1, 40 do
      lines[i] = ('%s %d'):format(word, i)
    end
    return lines
  end
  repo.write('a.txt', numbered('line'))
  repo.commit('first')
  repo.write('a.txt', numbered('edited'))
  repo.commit('second')
  repo.write('a.txt', numbered('again'))
end

--- Where the diff pane is looking.
--- @param s gitview.Session
--- @return integer row
local function diff_row(s)
  return vim.api.nvim_win_get_cursor(s.diff_win)[1]
end

-- The pane is one buffer for the life of the session, so a position in it
-- outlives the contents it belonged to. Merely clamping it leaves a shorter
-- diff opening at its end.
test('session: showing something else puts the diff pane back at the start', function()
  with_session(long_history, function(s)
    show_commit(s, 1)
    assert(vim.api.nvim_buf_line_count(s.diff_buf) > 50, 'the fixture should be long')
    vim.api.nvim_win_set_cursor(s.diff_win, { 50, 0 })
    show_commit(s, 2)
    eq(1, diff_row(s))
  end)
end)

test('session: moving to another file puts the diff pane back at the start', function()
  with_session(long_history, function(s, repo)
    repo.write('b.txt', { 'new' })
    session.refresh(s)
    settle(s)
    session.select(s, 1)
    vim.api.nvim_win_set_cursor(s.diff_win, { 30, 0 })
    session.select(s, 2)
    eq(1, diff_row(s))
  end)
end)

-- Staging a hunk redraws the same file, and being thrown back to the top on
-- every `s` would make working down a diff impossible.
test('session: staging keeps the position in the diff', function()
  with_session(long_history, function(s)
    session.select(s, 1)
    local row = changed_row(s, 'again 20')
    put_cursor(s, row)
    press_diff(s, 's')
    eq('staged', require('gitview.diff.render').view_of(s.diff_buf).lines[row].stage)
    eq(row, diff_row(s))
  end)
end)

test('session: a refresh that changes nothing keeps the position in the diff', function()
  with_session(long_history, function(s)
    session.select(s, 1)
    vim.api.nvim_win_set_cursor(s.diff_win, { 25, 0 })
    session.refresh(s)
    settle(s)
    eq(25, diff_row(s))
  end)
end)

-- A file keeps its place even when a refresh moves it to another index, which
-- is why what is shown is compared rather than the selection itself.
test('session: the position survives a file moving in the list', function()
  with_session(long_history, function(s, repo)
    session.select(s, 1)
    vim.api.nvim_win_set_cursor(s.diff_win, { 25, 0 })
    repo.write('0-first.txt', { 'new' })
    session.refresh(s)
    settle(s)
    eq(2, selected(s))
    eq('a.txt', s.entries[selected(s)].path)
    eq(25, diff_row(s))
  end)
end)

--- A history that forks and merges, so that a range can be asked for across it.
--- The commit list is newest first: merge side, on main, on side, first.
local function forked_history(repo)
  repo.write('base.txt', { 'base' })
  repo.commit('first')
  repo.git('checkout', '-q', '-b', 'side')
  repo.write('side.txt', { 'side' })
  repo.commit('on side')
  repo.git('checkout', '-q', '-')
  repo.write('main.txt', { 'main' })
  repo.commit('on main')
  repo.git('merge', '-q', '--no-ff', 'side', '-m', 'merge side')
  repo.write('base.txt', { 'edited' })
end

--- Put the cursor on a commit row without drawing, so a test can mark it.
--- @param s gitview.Session
--- @param index integer
local function goto_commit(s, index)
  local row = assert(list.row_of(s.commits_buf, { kind = 'commit', index = index }))
  vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
  s.selected = { kind = 'commit', index = index }
end

--- @param s gitview.Session
--- @return string
local function diff_winbar(s)
  vim.g.statusline_winid = s.diff_win
  local bar = require('gitview.diff.render').winbar()
  return (bar:gsub('%%#%w+#', ''):gsub('%%%*', ''):gsub('%%<$', ''))
end

--- The rows of `buf` the cursor paint is on, 1-based.
--- @param buf integer
--- @return integer[]
local function painted_rows(buf)
  local ns = vim.api.nvim_create_namespace('gitview.ui.list.cursor')
  return vim.tbl_map(function(m)
    return m[2] + 1
  end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
end

-- Both panes have a cursor line, so the paint is what says which one the diff
-- is following.
test('session: only the pane the diff follows has its row painted', function()
  with_session(forked_history, function(s)
    eq({ 1 }, painted_rows(s.files_buf))
    eq({}, painted_rows(s.commits_buf))
    local row = assert(list.row_of(s.commits_buf, { kind = 'commit', index = 2 }))
    vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
    session.follow_cursor(s, s.commits_win)
    eq({}, painted_rows(s.files_buf))
    eq({ row }, painted_rows(s.commits_buf))
  end)
end)

--- The rows of the commits pane the range is painted on, 1-based and
--- inclusive, or nil.
--- @param s gitview.Session
--- @return {[1]:integer, [2]:integer}?
local function painted_range(s)
  local ns = vim.api.nvim_create_namespace('gitview.ui.list.range')
  local m = vim.api.nvim_buf_get_extmarks(s.commits_buf, ns, 0, -1, { details = true })[1]
  return m and { m[2] + 1, m[4].end_row } or nil
end

--- @param s gitview.Session
--- @return string
local function commits_pane_winbar(s)
  vim.g.statusline_winid = s.commits_win
  return (list.winbar():gsub('%%#%w+#', ''))
end

-- The range is painted from the mark to the cursor, and the cursor line, whose
-- background would run into the range's, is off meanwhile.
test('session: the rows of a range are painted', function()
  with_session(forked_history, function(s)
    local mark_row = assert(list.row_of(s.commits_buf, { kind = 'commit', index = 3 }))
    goto_commit(s, 3)
    session.set_mark(s)
    eq(s.commits[3].sha, s.mark)
    -- a range of one row still says there is a mark
    eq({ mark_row, mark_row }, painted_range(s))
    assert(commits_pane_winbar(s):find('range of 1', 1, true), commits_pane_winbar(s))
    eq(false, vim.wo[s.commits_win].cursorline)

    local row = assert(list.row_of(s.commits_buf, { kind = 'commit', index = 1 }))
    vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
    session.follow_cursor(s, s.commits_win)
    eq({ row, mark_row }, painted_range(s))
    assert(commits_pane_winbar(s):find('range of 3', 1, true), commits_pane_winbar(s))
  end)
end)

-- `m` only ever marks, so a range is started again from anywhere with one key.
test('session: marking elsewhere moves the mark, and marking it again keeps it', function()
  with_session(forked_history, function(s)
    goto_commit(s, 2)
    session.set_mark(s)
    session.set_mark(s)
    eq(s.commits[2].sha, s.mark)
    goto_commit(s, 3)
    session.set_mark(s)
    eq(s.commits[3].sha, s.mark)
  end)
end)

test('session: <Esc> clears the mark from anywhere in the pane', function()
  with_session(forked_history, function(s)
    goto_commit(s, 3)
    session.set_mark(s)
    goto_commit(s, 1)
    vim.api.nvim_set_current_win(s.commits_win)
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'mx', false)
    eq(nil, s.mark)
    eq(nil, painted_range(s))
    assert(not commits_pane_winbar(s):find('range', 1, true), commits_pane_winbar(s))
    eq(true, vim.wo[s.commits_win].cursorline)
  end)
end)

-- A global mapping that starts with a pane's key would otherwise make the key
-- wait for the rest of it, and run that mapping when the next key comes soon.
test('session: no key of a pane waits for a longer global mapping', function()
  with_session(forked_history, function(s)
    for _, buf in ipairs({ s.files_buf, s.commits_buf, s.diff_buf }) do
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        eq(1, m.nowait, m.lhs)
      end
    end
  end)
end)

-- The pane maps `<Esc>` for itself, which hides a global mapping of it, so with
-- nothing to clear the global one is run instead.
test('session: <Esc> with no mark does what it does elsewhere', function()
  local ran = 0
  vim.keymap.set('n', '<Esc>', function()
    ran = ran + 1
  end)
  local ok, err = pcall(with_session, forked_history, function(s)
    vim.api.nvim_set_current_win(s.commits_win)
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'mx', false)
    eq(1, ran)
    -- not with a mark to clear
    goto_commit(s, 2)
    session.set_mark(s)
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'mx', false)
    eq(1, ran)
  end)
  vim.keymap.del('n', '<Esc>')
  assert(ok, err)
end)

-- A commit's files are not the rows the range was painted on.
test('session: looking into a range takes its paint away', function()
  with_session(forked_history, function(s)
    goto_commit(s, 3)
    session.set_mark(s)
    goto_commit(s, 1)
    session.enter(s)
    eq(nil, painted_range(s))
    eq(true, vim.wo[s.commits_win].cursorline)
    session.leave(s)
    eq({
      list.row_of(s.commits_buf, { kind = 'commit', index = 1 }),
      list.row_of(s.commits_buf, { kind = 'commit', index = 3 }),
    }, painted_range(s))
  end)
end)

-- The list is newest first, so which of the two is the old side follows from
-- where they sit rather than from their dates. Both ends are in the range, as
-- in a selection.
test('session: a mark and the cursor compare the stretch between them', function()
  with_session(forked_history, function(s)
    goto_commit(s, 4)
    session.set_mark(s)
    goto_commit(s, 1)
    session.show_selected(s)
    local label = ('%s^..%s'):format(s.commits[4].sha, s.commits[1].sha)
    assert(diff_winbar(s):find(label, 1, true), diff_winbar(s))
    -- everything from the root commit, which has no parent, to the merge
    eq({ 'base.txt', 'main.txt', 'side.txt' }, vim.tbl_map(function(f)
      return f.label
    end, require('gitview.diff.render').view_of(s.diff_buf).files))
  end)
end)

test('session: marking in the other direction gives the same range', function()
  with_session(forked_history, function(s)
    goto_commit(s, 1)
    session.set_mark(s)
    goto_commit(s, 4)
    session.show_selected(s)
    local label = ('%s^..%s'):format(s.commits[4].sha, s.commits[1].sha)
    assert(diff_winbar(s):find(label, 1, true), diff_winbar(s))
  end)
end)

--- Run `fn` and return what it said through `vim.notify`.
--- @param fn fun()
--- @return string[]
local function notified(fn)
  local notify = vim.notify
  local messages = {}
  vim.notify = function(msg)
    messages[#messages + 1] = msg
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return messages
end

-- `]r` is `j` in the commits pane pressed from the diff, so it passes through
-- the working-tree row as `j` would, and stops at either end of the list.
test('session: `]r` in the diff moves the commits pane and leaves the focus in the diff', function()
  with_session(forked_history, function(s)
    vim.api.nvim_set_current_win(s.commits_win)
    eq('worktree', s.selected.kind)
    press_diff(s, ']r')
    eq({ kind = 'commit', index = 1 }, s.selected)
    eq(list.row_of(s.commits_buf, s.selected), vim.api.nvim_win_get_cursor(s.commits_win)[1])
    eq(s.diff_win, vim.api.nvim_get_current_win())
    press_diff(s, ']r]r]r')
    eq({ kind = 'commit', index = 4 }, s.selected)
    local messages = notified(function()
      press_diff(s, ']r')
    end)
    eq({ kind = 'commit', index = 4 }, s.selected)
    assert(messages[1]:find('no older commit', 1, true), messages[1])
    for _ = 1, 4 do
      press_diff(s, '[r')
    end
    eq('worktree', s.selected.kind)
    messages = notified(function()
      press_diff(s, '[r')
    end)
    eq('worktree', s.selected.kind)
    assert(messages[1]:find('no newer commit', 1, true), messages[1])
  end)
end)

test('session: `]r` with a mark moves the cursor end of the range', function()
  with_session(forked_history, function(s)
    goto_commit(s, 1)
    session.set_mark(s)
    press_diff(s, ']r]r')
    eq(s.commits[1].sha, s.mark)
    eq({ kind = 'commit', index = 3 }, s.selected)
    local label = ('%s^..%s'):format(s.commits[3].sha, s.commits[1].sha)
    assert(diff_winbar(s):find(label, 1, true), diff_winbar(s))
  end)
end)

test('session: `]r` looking into a commit looks into the next one', function()
  with_session(forked_history, function(s)
    goto_commit(s, 2)
    session.enter(s)
    put_cursor(s, 1)
    press_diff(s, ']r')
    eq(s.commits[3].sha .. ' on side', s.scope.label)
    eq({ kind = 'commit_file', index = 1 }, s.selected)
    eq({ 'side.txt' }, vim.tbl_map(function(c)
      return c.path
    end, s.scope.changes))
    eq(s.diff_win, vim.api.nvim_get_current_win())
    press_diff(s, '[r[r')
    eq(s.commits[1].sha .. ' merge side', s.scope.label)
    -- the working tree on its own is not looked into
    local messages = notified(function()
      press_diff(s, '[r')
    end)
    eq(s.commits[1].sha .. ' merge side', s.scope.label)
    assert(messages[1]:find('no newer commit', 1, true), messages[1])
    -- backing out lands on the commit stepped to, not the one first looked into
    session.leave(s)
    eq({ kind = 'commit', index = 1 }, s.selected)
  end)
end)

test('session: `]r` looking into a range is refused', function()
  with_session(forked_history, function(s)
    goto_commit(s, 3)
    session.set_mark(s)
    goto_commit(s, 1)
    session.enter(s)
    local label = s.scope.label
    local messages = notified(function()
      press_diff(s, ']r')
    end)
    eq(label, s.scope.label)
    assert(messages[1]:find('range', 1, true), messages[1])
  end)
end)

-- The mark is what made it a range when it was looked into, and clearing it
-- afterwards does not make the files on screen one commit's.
test('session: `]r` looking into a range is refused even after the mark is cleared', function()
  with_session(forked_history, function(s)
    goto_commit(s, 3)
    session.set_mark(s)
    goto_commit(s, 1)
    session.enter(s)
    session.clear_mark(s)
    local label = s.scope.label
    notified(function()
      press_diff(s, ']r')
    end)
    eq(label, s.scope.label)
  end)
end)

test('session: `]r` on an uncommitted file is refused', function()
  with_session(forked_history, function(s)
    session.select(s, 1)
    local messages = notified(function()
      press_diff(s, ']r')
    end)
    eq({ kind = 'file', index = 1 }, s.selected)
    assert(messages[1]:find('no commit', 1, true), messages[1])
  end)
end)

-- The cursor on the mark itself is not a range of nothing; it is the one commit.
test('session: the cursor on the mark shows that commit alone', function()
  with_session(forked_history, function(s)
    goto_commit(s, 2)
    session.set_mark(s)
    session.show_selected(s)
    local commit = s.commits[2]
    assert(diff_winbar(s):find(commit.sha .. ' ' .. commit.subject, 1, true), diff_winbar(s))
  end)
end)

-- The shas of what the diff compares read in the commits pane's color, and the
-- subject is left alone.
test('session: the diff winbar colors the shas it names', function()
  with_session(forked_history, function(s)
    goto_commit(s, 2)
    session.show_selected(s)
    vim.g.statusline_winid = s.diff_win
    local bar = require('gitview.diff.render').winbar()
    local function sha(c)
      return '%#GitViewCommitSha#' .. c.sha .. '%#GitViewWinBarText#'
    end
    assert(bar:find(sha(s.commits[2]), 1, true), bar)
    eq(1, select(2, bar:gsub('GitViewCommitSha', '')))

    goto_commit(s, 3)
    session.set_mark(s)
    goto_commit(s, 1)
    session.show_selected(s)
    vim.g.statusline_winid = s.diff_win
    bar = require('gitview.diff.render').winbar()
    local range = sha(s.commits[3]) .. '^..' .. sha(s.commits[1])
    assert(bar:find(range, 1, true), bar)
  end)
end)

-- `git diff` compares the two trees whatever their history, but across a fork
-- the result also undoes what the other side did, so it is named rather than
-- refused.
test('session: a range across a fork says it is not one line of history', function()
  with_session(forked_history, function(s)
    -- 2 is `on main` and 3 is `on side`: the two branch tips
    goto_commit(s, 3)
    session.set_mark(s)
    goto_commit(s, 2)
    session.show_selected(s)
    assert(diff_winbar(s):find('diverged', 1, true), diff_winbar(s))
  end)
end)

test('session: a range along one line of history says nothing extra', function()
  with_session(forked_history, function(s)
    goto_commit(s, 4)
    session.set_mark(s)
    goto_commit(s, 2)
    session.show_selected(s)
    assert(not diff_winbar(s):find('diverged', 1, true), diff_winbar(s))
  end)
end)

-- A merge on its own is still compared with its first parent, and says so.
test('session: a merge on its own is still first parent', function()
  with_session(forked_history, function(s)
    goto_commit(s, 1)
    session.show_selected(s)
    assert(diff_winbar(s):find('first parent', 1, true), diff_winbar(s))
    -- only the side branch's file, not main's
    eq({ 'side.txt' }, vim.tbl_map(function(f)
      return f.label
    end, require('gitview.diff.render').view_of(s.diff_buf).files))
  end)
end)

test('session: looking into a range lists the files it changed', function()
  with_session(forked_history, function(s)
    goto_commit(s, 4)
    session.set_mark(s)
    goto_commit(s, 1)
    session.show_selected(s)
    session.enter(s)
    eq(('%s^..%s'):format(s.commits[4].sha, s.commits[1].sha), s.scope.label)
    eq({ 'base.txt', 'main.txt', 'side.txt' }, commit_rows(s))
    session.show_selected(s)
    eq('base.txt', require('gitview.diff.render').view_of(s.diff_buf).files[1].label)
    -- backing out returns to the commit the cursor was on, not to the mark
    session.leave(s)
    eq({ kind = 'commit', index = 1 }, s.selected)
  end)
end)

--- Run `fn` with the commit list limited to `n`, so that a test can push a
--- commit off the end of it.
--- @param n integer
--- @param fn fun()
local function with_commit_count(n, fn)
  local config = require('gitview.config')
  local kept = config.values.commit_count
  config.values.commit_count = n
  local ok, err = pcall(fn)
  config.values.commit_count = kept
  assert(ok, err)
end

--- @param s gitview.Session
--- @return string
local function commits_winbar(s)
  vim.g.statusline_winid = s.commits_win
  return (list.winbar():gsub('%%#%w+#', ''))
end

-- A mark left pointing at a commit no longer listed would widen every range
-- while no row showed where it was.
test('session: a refresh drops a mark that has left the list', function()
  with_session(forked_history, function(s)
    goto_commit(s, 4)
    session.set_mark(s)
    -- the cursor moves off the mark, so the list itself can be replaced
    goto_commit(s, 1)
    with_commit_count(2, function()
      session.refresh(s)
      settle(s)
    end)
    eq(2, #s.commits)
    eq(nil, s.mark)
  end)
end)

-- Replacing the list would put a different commit under the cursor and so switch
-- the diff pane to it. The commit itself is still readable, so the list waits.
test('session: a commit the log has dropped holds the list open', function()
  with_session(forked_history, function(s)
    goto_commit(s, 4)
    local dropped = s.commits[4].sha
    with_commit_count(2, function()
      session.refresh(s)
      settle(s)
      eq(4, #s.commits)
      eq(true, s.commits_stale)
      eq({ kind = 'commit', index = 4 }, s.selected)
      assert(commits_winbar(s):find('history changed', 1, true), commits_winbar(s))

      -- moving off it is what lets the list through, onto the row chosen rather
      -- than the row the cursor happened to be on
      local row = assert(list.row_of(s.commits_buf, { kind = 'commit', index = 1 }))
      vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
      session.follow_cursor(s, s.commits_win)
      eq(2, #s.commits)
      eq(nil, s.commits_stale)
      eq({ kind = 'commit', index = 1 }, s.selected)
      assert(not commits_winbar(s):find('history changed', 1, true), commits_winbar(s))
      for _, c in ipairs(s.commits) do
        assert(c.sha ~= dropped, 'the dropped commit should be gone from the list')
      end
    end)
  end)
end)

--- `history`, with an untracked file beside the change to a tracked one.
local function dirty_history(repo)
  history(repo)
  repo.write('loose.lua', { 'return 7' })
end

--- Put the cursor on the working-tree row without drawing.
--- @param s gitview.Session
local function goto_worktree(s)
  local row = assert(list.row_of(s.commits_buf, { kind = 'worktree', index = 1 }))
  vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
  s.selected = { kind = 'worktree', index = 1 }
end

--- @param s gitview.Session
--- @return string[] the label of every file in the view drawn
local function view_files(s)
  return vim.tbl_map(function(f)
    return f.label
  end, assert(require('gitview.diff.render').view_of(s.diff_buf), 'no view drawn').files)
end

-- A clean working tree compares nothing HEAD's own row does not, but the row is
-- still there to be marked as an end of a range.
test('session: a clean working tree still has a row of its own', function()
  with_session(function(repo)
    repo.write('a.txt', { 'one' })
    repo.commit('first')
  end, function(s)
    local zeros = ('0'):rep(#s.commits[1].sha)
    eq({ zeros .. ' uncommitted changes', s.commits[1].sha .. ' first' }, commit_rows(s))
    goto_worktree(s)
    session.show_selected(s)
    eq({ list.EMPTY_NOTICE }, diff_rows(s))
  end)
end)

test('session: the working-tree row shows everything uncommitted at once', function()
  with_session(dirty_history, function(s)
    goto_worktree(s)
    session.show_selected(s)
    eq({ 'a.lua', 'loose.lua' }, view_files(s))
    -- what the files pane shows a file at a time: staged and unstaged together
    assert(require('gitview.diff.render').view_of(s.diff_buf).mixed, 'the view should be mixed')
  end)
end)

test('session: a mark and the working-tree row compare the commit with the working tree', function()
  with_session(dirty_history, function(s)
    -- `second` and the working tree, so the range starts at `first`
    goto_commit(s, 1)
    session.set_mark(s)
    goto_worktree(s)
    session.show_selected(s)
    local label = s.commits[1].sha .. '^..working tree'
    assert(diff_winbar(s):find(label, 1, true), diff_winbar(s))
    eq({ 'a.lua', 'added.lua', 'loose.lua' }, view_files(s))
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('return 1', 1, true), text)
    assert(text:find('return 3', 1, true), text)
    assert(not text:find('return 2', 1, true), text)
    eq(nil, require('gitview.diff.render').view_of(s.diff_buf).mixed)
  end)
end)

test('session: marking the working-tree row gives the same range', function()
  with_session(dirty_history, function(s)
    goto_worktree(s)
    session.set_mark(s)
    eq(list.WORKTREE, s.mark)
    eq({ 1, 1 }, painted_range(s))
    goto_commit(s, 2)
    session.show_selected(s)
    local label = s.commits[2].sha .. '^..working tree'
    assert(diff_winbar(s):find(label, 1, true), diff_winbar(s))
    -- `first` is the root commit, so the range starts from nothing
    eq({ 'a.lua', 'added.lua', 'loose.lua' }, view_files(s))
    assert(not table.concat(diff_rows(s), '\n'):find('return 1', 1, true))
  end)
end)

-- The working tree on its own has nothing to look into that the files pane does
-- not already list.
test('session: <CR> on the working-tree row goes to the files pane', function()
  with_session(dirty_history, function(s)
    goto_worktree(s)
    vim.api.nvim_set_current_win(s.commits_win)
    session.enter(s)
    eq(s.files_win, vim.api.nvim_get_current_win())
    eq(nil, s.scope)
  end)
end)

test('session: looking into a range ending at the working tree', function()
  with_session(dirty_history, function(s)
    goto_commit(s, 2)
    session.set_mark(s)
    goto_worktree(s)
    session.enter(s)
    eq(s.commits[2].sha .. '^..working tree', s.scope.label)
    eq({ 'a.lua', 'added.lua', 'loose.lua' }, commit_rows(s))
    session.show_selected(s)
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('return 3', 1, true), text)
    -- backing out lands on the row it went in from
    session.leave(s)
    eq({ kind = 'worktree', index = 1 }, s.selected)
  end)
end)

test('session: a refresh lists again the files of a range ending at the working tree', function()
  with_session(history, function(s, repo)
    goto_commit(s, 1)
    session.set_mark(s)
    goto_worktree(s)
    session.enter(s)
    eq({ 'a.lua', 'added.lua' }, commit_rows(s))
    repo.write('new.lua', { 'return 8' })
    session.refresh(s)
    settle(s)
    eq({ 'a.lua', 'added.lua', 'new.lua' }, commit_rows(s))
  end)
end)

-- An automatic refresh leaves a commit's view alone, since a sha names contents
-- that cannot change. The working tree can, whichever end of the range it is.
test('session: an automatic refresh redraws a range ending at the working tree', function()
  with_session(history, function(s, repo)
    goto_worktree(s)
    session.set_mark(s)
    goto_commit(s, 1)
    session.show_selected(s)
    assert(table.concat(diff_rows(s), '\n'):find('return 3', 1, true))
    repo.write('a.lua', { 'return 4' })
    session.refresh(s, { auto = true })
    settle(s)
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('return 4', 1, true), text)
  end)
end)

test('session: a mark on the working-tree row stays once nothing is uncommitted', function()
  with_session(history, function(s, repo)
    goto_worktree(s)
    session.set_mark(s)
    repo.commit('third')
    session.refresh(s)
    settle(s)
    eq(list.WORKTREE, s.mark)
    eq({ kind = 'worktree', index = 1 }, list.target_at(s.commits_buf, 1))
  end)
end)

-- Marked while nothing is uncommitted, the range is there for the edits to come.
test('session: a range from a clean working tree picks up later edits', function()
  with_session(function(repo)
    repo.write('a.lua', { 'return 1' })
    repo.commit('first')
    repo.write('a.lua', { 'return 2' })
    repo.commit('second')
  end, function(s, repo)
    goto_worktree(s)
    session.set_mark(s)
    goto_commit(s, 2)
    session.show_selected(s)
    assert(table.concat(diff_rows(s), '\n'):find('return 2', 1, true))
    repo.write('a.lua', { 'return 3' })
    session.refresh(s, { auto = true })
    settle(s)
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('return 3', 1, true), text)
  end)
end)

--- A file whose working tree differs from HEAD in whitespace on one line and in
--- earnest on another.
local function whitespace(repo)
  repo.write('a.txt', { 'a', 'b', 'c' })
  repo.commit('init')
  repo.write('a.txt', { 'a', '  b  ', 'C' })
end

--- @param s gitview.Session
--- @return string[] the text of every row standing for a source line
local function source_rows(s)
  local view = assert(require('gitview.diff.render').view_of(s.diff_buf), 'no view drawn')
  local out = {}
  for _, l in ipairs(view.lines) do
    if require('gitview.diff.lines').source_kinds[l.kind] then
      out[#out + 1] = ('%s %s'):format(l.kind, l.text)
    end
  end
  return out
end

test('session: ignoring whitespace folds a whitespace-only change away', function()
  with_session(whitespace, function(s)
    session.select(s, 1)
    eq({ 'context a', 'del b', 'del c', 'add   b  ', 'add C' }, source_rows(s))
    session.toggle_whitespace(s)
    eq(true, s.ignore_whitespace)
    eq({ 'context a', 'context b', 'del c', 'add C' }, source_rows(s))
    session.toggle_whitespace(s)
    eq({ 'context a', 'del b', 'del c', 'add   b  ', 'add C' }, source_rows(s))
  end)
end)

-- A mode that changes which lines count as different has to say so, or the
-- reader has no way to tell a folded change from no change.
test('session: the winbar says when whitespace is being ignored', function()
  with_session(whitespace, function(s)
    session.select(s, 1)
    assert(not diff_winbar(s):find('   -w', 1, true), diff_winbar(s))
    session.toggle_whitespace(s)
    assert(diff_winbar(s):find('   -w', 1, true), diff_winbar(s))
  end)
end)

-- Calling a file whose only change is whitespace "no textual change" would be a
-- lie, and it is the one case where the fold hides everything there was.
test('session: a change that is only whitespace says which it is', function()
  with_session(function(repo)
    repo.write('a.txt', { 'a', 'b' })
    repo.commit('init')
    repo.write('a.txt', { 'a', '  b  ' })
  end, function(s)
    session.select(s, 1)
    session.toggle_whitespace(s)
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('no change outside whitespace', 1, true), text)
  end)
end)

-- Writing the shown rows back would leave the folded line at its index version
-- while the working tree kept the other, and the view would go on showing
-- nothing unstaged.
test('session: staging by row is refused while whitespace is ignored', function()
  with_session(whitespace, function(s, repo)
    session.select(s, 1)
    session.toggle_whitespace(s)
    local before = repo.git('status', '--short')
    press_diff(s, 's')
    press_diff(s, 'S')
    press_diff(s, 'u')
    eq(before, repo.git('status', '--short'))
  end)
end)

-- Whole-file staging is `git add` and reads no rows, so the fold cannot mislead
-- it. That is what makes refusing only the row-level keys the right line.
test('session: staging the whole file still works while whitespace is ignored', function()
  with_session(whitespace, function(s, repo)
    session.select(s, 1)
    session.toggle_whitespace(s)
    press(s, 's')
    eq('M  a.txt\n', repo.git('status', '--short'))
    -- and the whitespace went in with it, since git add took the file as it is
    eq('', repo.git('diff'))
  end)
end)

test('session: the toggle reaches a commit view too', function()
  with_session(function(repo)
    repo.write('a.txt', { 'a', 'b' })
    repo.commit('init')
    repo.write('a.txt', { 'a', '  b  ' })
    repo.commit('whitespace only')
  end, function(s)
    show_commit(s, 1)
    eq({ 'context a', 'del b', 'add   b  ' }, source_rows(s))
    session.toggle_whitespace(s)
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('no change outside whitespace', 1, true), text)
  end)
end)

--- A history whose newer commit has a body, written with more than one blank
--- line after its subject.
local function described_history(repo)
  repo.write('a.lua', { 'return 1' })
  repo.commit('first')
  repo.write('a.lua', { 'return 2' })
  repo.write('b.lua', { 'return 3', 'return 4' })
  repo.git('add', '-A')
  repo.git('commit', '-qm', 'second\n\n\nwhy\n\nmore')
  repo.write('a.lua', { 'return 5' })
end

--- @param s gitview.Session
--- @return gitview.View
local function diff_view(s)
  return assert(require('gitview.diff.render').view_of(s.diff_buf))
end

--- @param s gitview.Session
--- @return integer? last row of the header's closed fold, nil when open
local function header_closed(s)
  return vim.api.nvim_win_call(s.diff_win, function()
    local row = vim.fn.foldclosed(2)
    return row ~= -1 and vim.fn.foldclosedend(2) or nil
  end)
end

--- Open or close the header's fold with `key`, from the row it folds from: the
--- subject above it is in no fold.
--- @param s gitview.Session
--- @param key string
local function fold_header(s, key)
  vim.api.nvim_win_call(s.diff_win, function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd('normal! ' .. key)
  end)
end

test('session: a commit is introduced by its message and stat', function()
  with_session(described_history, function(s)
    show_commit(s, 1)
    local got = diff_rows(s)
    eq('second', got[1])
    assert(got[2]:find('^test <test@example.com>   '), got[2])
    eq({
      '',
      'why',
      '',
      'more',
      '',
      ' a.lua | 2 +-',
      ' b.lua | 2 ++',
      ' 2 files changed, 3 insertions(+), 1 deletion(-)',
      '',
      'a.lua',
    }, vim.list_slice(got, 3, 12))

    -- every row the view points at has moved down past the header
    local view = diff_view(s)
    eq(10, view.header_rows)
    eq({ 12, 16 }, view.file_rows)
    eq(12, view.files[1].row)
    local dlib = require('gitview.diff.lines')
    for _, r in ipairs(view.hunk_rows) do
      assert(dlib.source_kinds[view.lines[r].kind], 'hunk row ' .. r)
    end
  end)
end)

test('session: the stat graph is colored as git colors it', function()
  with_session(described_history, function(s)
    show_commit(s, 1)
    local ns = vim.api.nvim_create_namespace('gitview.diff')
    -- ' a.lua | 2 +-' is row 8
    local marks = vim.api.nvim_buf_get_extmarks(s.diff_buf, ns, { 7, 0 }, { 7, -1 }, {
      details = true,
    })
    local got = {}
    for _, m in ipairs(marks) do
      got[#got + 1] = { m[3], m[4].end_col, m[4].hl_group }
    end
    table.sort(got, function(a, b)
      return a[1] < b[1]
    end)
    eq({ { 11, 12, 'GitViewStatAdd' }, { 12, 13, 'GitViewStatDelete' } }, got)
  end)
end)

-- The diff pane is not the current window when a commit is drawn, and
-- 'foldexpr' still has to read the diff's view rather than the current
-- window's.
test('session: the header starts folded below its subject, and reads as its byline', function()
  with_session(described_history, function(s)
    show_commit(s, 1)
    assert(vim.api.nvim_get_current_win() ~= s.diff_win)
    eq(10, header_closed(s))
    local subject_folded = vim.api.nvim_win_call(s.diff_win, function()
      return vim.fn.foldclosed(1) ~= -1
    end)
    eq(false, subject_folded, 'the subject stays in view')
    local text = vim.api.nvim_win_call(s.diff_win, function()
      vim.v.foldstart = 2
      vim.v.foldend = 10
      return require('gitview.diff.render').foldtext()
    end)
    local commit = s.commits[1]
    eq({
      { ('\u{25b8} %s · %s   2 files '):format(commit.author, commit.when), 'GitViewCommitAuthor' },
    }, text)
  end)
end)

--- @param s gitview.Session
--- @param row integer
--- @return string
local function diff_gutter(s, row)
  vim.g.statusline_winid = s.diff_win
  vim.v.lnum = row
  return require('gitview.diff.render').statuscolumn()
end

test("session: a folded header's gutter ends with how many lines the commit changed", function()
  with_session(described_history, function(s)
    show_commit(s, 1)
    eq((' '):rep(6) .. '%#GitViewStatAdd#+3 %#GitViewStatDelete#-1 ', diff_gutter(s, 2))
    eq((' '):rep(12), diff_gutter(s, 1), 'the subject has no count')
    -- opened, the stat says as much
    fold_header(s, 'zo')
    eq((' '):rep(12), diff_gutter(s, 2))
  end)
end)

-- Replacing the lines under an open fold closes it or not depending on how its
-- extent changed, so what the reader chose is carried over explicitly.
test('session: an opened header stays open from one commit to the next', function()
  with_session(described_history, function(s)
    show_commit(s, 1)
    fold_header(s, 'zo')
    -- the root commit's header is shorter
    show_commit(s, 2)
    eq(nil, header_closed(s))
    show_commit(s, 1)
    eq(nil, header_closed(s))

    fold_header(s, 'zc')
    show_commit(s, 2)
    eq(5, header_closed(s))
  end)
end)

--- Two commits changing the same lines of one file, so that each folds the
--- same rows.
local function spread_history(repo)
  repo.write('f.txt', spread_lines({ [2] = 'line 2', [19] = 'line 19' }))
  repo.commit('init')
  repo.write('f.txt', spread_lines())
  repo.commit('first')
  repo.write('f.txt', spread_lines({ [2] = 'two', [19] = 'nineteen' }))
  repo.commit('second')
end

-- The header is carried over from one commit to the next, but a run of
-- unchanged lines is only the same run in the same comparison.
test('session: an opened run is closed again in another commit', function()
  with_session(spread_history, function(s)
    show_commit(s, 1)
    open_fold(s, 'line 10')
    show_commit(s, 2)
    eq(false, fold_open(s, 'line 10'))
    show_commit(s, 1)
    eq(false, fold_open(s, 'line 10'))
  end)
end)

-- Moving the mark compares something else while the same commit is selected.
test('session: an opened run is closed again in another range', function()
  with_session(spread_history, function(s)
    goto_commit(s, 2)
    session.set_mark(s)
    show_commit(s, 1)
    open_fold(s, 'line 10')
    session.clear_mark(s)
    eq(false, fold_open(s, 'line 10'))
  end)
end)

-- A fold no longer than 'foldminlines' is never shown closed, and reads as open
-- to the check that carries the reader's choice over to the next commit: one
-- short header would leave every header after it open.
test('session: a short header folds whatever the user has foldminlines at', function()
  local saved = vim.o.foldminlines
  -- Counted in screen lines, so it is set well past the header's rows whatever
  -- the window's width does to them.
  vim.o.foldminlines = 20
  local ok, err = pcall(with_session, described_history, function(s)
    show_commit(s, 2)
    eq(5, header_closed(s))
    show_commit(s, 1)
    eq(10, header_closed(s))
  end)
  vim.o.foldminlines = saved
  assert(ok, err)
end)

--- Move the commits pane's cursor onto a row and follow it, as `CursorMoved`
--- does: unlike `show_commit`, a commit is then read in the background.
--- @param s gitview.Session
--- @param target gitview.ListTarget
local function land_on(s, target)
  local row = assert(list.row_of(s.commits_buf, target))
  vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
  session.follow_cursor(s, s.commits_win)
end

--- Wait for what is being read in the background to be drawn.
--- @param s gitview.Session
local function wait_read(s)
  local done = vim.wait(5000, function()
    return not s.loading and not s.pending
  end)
  assert(done, 'the view was never read')
end

test('session: a commit the cursor lands on shows its header while it is read', function()
  with_session(described_history, function(s)
    land_on(s, { kind = 'commit', index = 1 })
    -- what the log already gave, before anything else is read
    eq({ 'second', 'test   ' .. s.commits[1].when, '', '(loading…)' }, diff_rows(s))
    eq(2, diff_view(s).header_rows)

    wait_read(s)
    eq(10, diff_view(s).header_rows)
    assert(vim.tbl_contains(diff_rows(s), 'a.lua'), table.concat(diff_rows(s), '\n'))
  end)
end)

--- Wait for the diff pane to show the view of `subject`.
--- @param s gitview.Session
--- @param subject string
local function wait_shown(s, subject)
  local done = vim.wait(1000, function()
    local rows = diff_rows(s)
    return rows[1] == subject and not vim.tbl_contains(rows, '(loading…)')
  end)
  assert(done, table.concat(diff_rows(s), '\n'))
end

test('session: a commit read once is drawn without a placeholder the next time', function()
  with_session(described_history, function(s)
    land_on(s, { kind = 'commit', index = 1 })
    wait_read(s)
    land_on(s, { kind = 'commit', index = 2 })
    wait_read(s)
    land_on(s, { kind = 'commit', index = 1 })
    -- nothing to read, and the previous view stays until the next turn
    eq(nil, s.loading)
    eq(nil, s.pending)
    eq('first', diff_rows(s)[1])
    wait_shown(s, 'second')
    eq(10, diff_view(s).header_rows)
  end)
end)

-- A commit read before is drawn a turn later, so that one passed over in the
-- meantime is never drawn at all.
test('session: sweeping commits read before draws only the last', function()
  with_session(described_history, function(s)
    land_on(s, { kind = 'commit', index = 1 })
    wait_read(s)
    land_on(s, { kind = 'commit', index = 2 })
    wait_read(s)

    local vlib = require('gitview.diff.view')
    local build = vlib.build
    local builds = 0
    vlib.build = function(...)
      builds = builds + 1
      return build(...)
    end
    local ok, err = pcall(function()
      land_on(s, { kind = 'commit', index = 1 })
      land_on(s, { kind = 'commit', index = 2 })
      land_on(s, { kind = 'commit', index = 1 })
      wait_shown(s, 'second')
      vim.wait(50)
      eq(1, builds)
    end)
    vlib.build = build
    assert(ok, err)
  end)
end)

--- Run `fn` counting the ranges read from git.
--- @param fn fun(reads: fun(): integer)
local function counting_range_reads(fn)
  local source = require('gitview.diff.source')
  local for_range = source.for_range
  local n = 0
  source.for_range = function(...)
    n = n + 1
    return for_range(...)
  end
  local ok, err = pcall(fn, function()
    return n
  end)
  source.for_range = for_range
  assert(ok, err)
end

test('session: a range between two commits is read from git once', function()
  with_session(described_history, function(s)
    counting_range_reads(function(reads)
      show_commit(s, 1)
      show_commit(s, 2)
      show_commit(s, 1)
      eq(2, reads())
      -- whitespace changes what is built from the contents, not the contents
      session.toggle_whitespace(s)
      eq(2, reads())
    end)
  end)
end)

-- The working tree can change under a range that ends at it, so it has no
-- contents to keep.
test('session: a range ending at the working tree is read every time', function()
  with_session(described_history, function(s)
    goto_worktree(s)
    session.set_mark(s)
    counting_range_reads(function(reads)
      show_commit(s, 1)
      show_commit(s, 1)
      eq(2, reads())
    end)
  end)
end)

-- Every row passed over asks for its view, and only the one the cursor stops on
-- is still wanted by the time a read could start.
test('session: sweeping the commits reads only the one in progress and the last', function()
  with_session(described_history, function(s)
    land_on(s, { kind = 'worktree', index = 1 })
    land_on(s, { kind = 'commit', index = 1 })
    land_on(s, { kind = 'commit', index = 2 })
    wait_read(s)
    eq(nil, s.details[s.commits[1].sha])
    eq('first', diff_rows(s)[1])
    eq(5, diff_view(s).header_rows)
  end)
end)

test('session: a file selected while a commit is read is not drawn over', function()
  with_session(described_history, function(s)
    land_on(s, { kind = 'commit', index = 1 })
    session.select(s, 1)
    wait_read(s)
    eq('file', s.selected.kind)
    eq(nil, diff_view(s).header_rows)
  end)
end)

-- The placeholder has the header's fold, so the reader's choice survives it.
test('session: an opened header stays open across a commit read in the background', function()
  with_session(described_history, function(s)
    show_commit(s, 1)
    fold_header(s, 'zo')
    land_on(s, { kind = 'commit', index = 2 })
    eq(nil, header_closed(s))
    wait_read(s)
    eq(nil, header_closed(s))
  end)
end)

-- A mark on a commit's own parent compares exactly what the commit alone does,
-- so that is a single commit too.
test('session: only a single commit has a header', function()
  with_session(function(repo)
    described_history(repo)
    repo.write('c.lua', { 'return 6' })
    repo.commit('third')
    repo.write('c.lua', { 'return 7' })
  end, function(s)
    -- an uncommitted file
    session.select(s, 1)
    eq(nil, diff_view(s).header_rows)

    -- a range of two commits: third, second, first
    goto_commit(s, 3)
    session.set_mark(s)
    goto_commit(s, 1)
    session.show_selected(s)
    eq(nil, diff_view(s).header_rows)
    eq('a.lua', diff_rows(s)[1])
    -- nothing is folded where there is no header
    eq(nil, header_closed(s))

    -- two rows, even if one of them adds nothing to the other
    goto_commit(s, 2)
    session.show_selected(s)
    eq(nil, diff_view(s).header_rows)

    -- the cursor on the mark is the one commit again
    goto_commit(s, 3)
    session.show_selected(s)
    eq(5, diff_view(s).header_rows)

    -- one file of a commit
    session.set_mark(s)
    show_commit(s, 1)
    session.enter(s)
    session.show_selected(s)
    eq(nil, diff_view(s).header_rows)
  end)
end)

-- Above the first file is no file, so the winbar names the commit alone.
test('session: the winbar names the commit over its header', function()
  with_session(described_history, function(s)
    show_commit(s, 1)
    local commit = s.commits[1]
    vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
    eq((' %s %s   [2 files]'):format(commit.sha, commit.subject), diff_winbar(s))
    -- only once the header of a file has scrolled off is it named
    local first = diff_view(s).files[1].row
    vim.api.nvim_win_call(s.diff_win, function()
      vim.fn.winrestview({ topline = first + 1, lnum = first + 1 })
    end)
    eq(first + 1, vim.fn.line('w0', s.diff_win))
    assert(diff_winbar(s):find('^ a.lua @ '), diff_winbar(s))
  end)
end)

--- A commit that leaves files out of its view: a binary one and a pure rename,
--- next to one that has lines to show.
local function skipping_history(repo)
  repo.write('doc.md', { 'text' })
  repo.write('a.lua', { 'return 1' })
  repo.commit('first')
  repo.git('mv', 'doc.md', 'guide.md')
  repo.write('a.lua', { 'return 2' })
  local f = assert(io.open(repo.root .. '/logo.png', 'wb'))
  f:write('PNG\0\1\2')
  f:close()
  repo.commit('second')
end

--- The rows of `kind` in the diff pane, as texts by row.
--- @param s gitview.Session
--- @param kind string
--- @return table<integer, string>
local function rows_of_kind(s, kind)
  local out = {}
  for row, l in ipairs(diff_view(s).lines) do
    if l.kind == kind then
      out[row] = l.text
    end
  end
  return out
end

-- Counting the files a view leaves out says less than naming them, and a
-- commit's stat names them already, so they are listed right below it.
test('session: a commit lists the files it leaves out below its header', function()
  with_session(skipping_history, function(s)
    show_commit(s, 1)
    local view = diff_view(s)
    local n = assert(view.header_rows)
    eq({
      [n + 2] = 'logo.png             (binary file)',
      [n + 3] = 'doc.md -> guide.md   (no textual change)',
    }, rows_of_kind(s, 'skipped'))
    eq('', diff_rows(s)[n + 4])
    eq('a.lua', diff_rows(s)[n + 5])
    eq({ n + 5 }, view.file_rows)
    eq(n + 5, view.files[1].row)
    for _, r in ipairs(view.hunk_rows) do
      assert(require('gitview.diff.lines').source_kinds[view.lines[r].kind], 'hunk row ' .. r)
    end
    -- out of the header's fold, which starts closed
    eq(n, header_closed(s))
    -- and no longer in the winbar
    assert(not diff_winbar(s):find('binary', 1, true), diff_winbar(s))
  end)
end)

test('session: a view without a header lists the files it leaves out at its top', function()
  with_session(function(repo)
    repo.write('doc.md', { 'text' })
    repo.write('a.lua', { 'return 1' })
    repo.commit('init')
    repo.git('mv', 'doc.md', 'guide.md')
    repo.write('a.lua', { 'return 2' })
  end, function(s)
    goto_commit(s, 1)
    s.selected = { kind = 'worktree', index = 1 }
    session.show_selected(s)
    eq(
      { 'doc.md -> guide.md   (no textual change)', '', 'a.lua' },
      vim.list_slice(diff_rows(s), 1, 3)
    )
    eq(3, diff_view(s).files[1].row)
  end)
end)

-- Saying only that there is no textual change would hide which files changed
-- and how, along with the commit's message.
test('session: a commit with nothing to show lists its files under its header', function()
  with_session(function(repo)
    repo.write('doc.md', { 'text' })
    repo.commit('first')
    repo.git('mv', 'doc.md', 'guide.md')
    repo.commit('second')
  end, function(s)
    show_commit(s, 1)
    local view = diff_view(s)
    eq({}, view.files)
    eq('second', diff_rows(s)[1])
    eq(
      { [view.header_rows + 2] = 'doc.md -> guide.md   (no textual change)' },
      rows_of_kind(s, 'skipped')
    )
  end)
end)

-- An empty commit, such as one amended for its message alone, still has a
-- message to read.
test('session: a commit that changed nothing keeps its header', function()
  with_session(function(repo)
    repo.write('a.lua', { 'return 1' })
    repo.commit('first')
    repo.git('commit', '-q', '--allow-empty', '-m', 'second', '-m', 'Why it is empty.')
  end, function(s)
    show_commit(s, 1)
    local view = diff_view(s)
    local n = assert(view.header_rows)
    eq('second', diff_rows(s)[1])
    assert(vim.tbl_contains(diff_rows(s), 'Why it is empty.'), 'the body is shown')
    eq('(no change)', diff_rows(s)[n + 2])
    eq({}, view.files)
  end)
end)

-- With whitespace ignored, a file whose only change is whitespace has nothing to
-- show either, and calling that "no textual change" would be a lie.
test('session: a file left out for its whitespace says so', function()
  with_session(function(repo)
    repo.write('a.lua', { 'return 1' })
    repo.write('b.lua', { 'return 1' })
    repo.commit('first')
    repo.write('a.lua', { 'return  1' })
    repo.write('b.lua', { 'return 2' })
    repo.commit('second')
  end, function(s)
    session.toggle_whitespace(s)
    show_commit(s, 1)
    local listed = vim.tbl_values(rows_of_kind(s, 'skipped'))
    eq({ 'a.lua   (no change outside whitespace)' }, listed)
  end)
end)

--- A commit with a long subject, partly in wide characters, that changed two
--- files. Every line changes, so nothing is folded and no syntax is left to be
--- filled in after the draw.
local function long_subject(repo)
  repo.write('a.lua', { 'return 1', 'return 2', 'return 3' })
  repo.write('b.lua', { 'return 0' })
  repo.commit('first')
  repo.write('a.lua', { 'return -1', 'return -2', 'return -3' })
  repo.write('b.lua', { 'return 00' })
  repo.commit('Make the subject of this commit long 長い件名を窓に収まるように切る')
end

--- The diff pane's winbar as drawn, in a pane `width` cells wide, with the top
--- of the window inside the first file.
--- @param s gitview.Session
--- @param width integer
--- @return string
local function drawn_winbar(s, width)
  vim.api.nvim_win_set_width(s.diff_win, width)
  eq(width, vim.api.nvim_win_get_width(s.diff_win))
  local row = diff_view(s).files[1].row + 1
  vim.api.nvim_win_call(s.diff_win, function()
    vim.fn.winrestview({ topline = row, lnum = row })
  end)
  local bar = vim.api.nvim_eval_statusline(
    vim.wo[s.diff_win].winbar,
    { winid = s.diff_win, use_winbar = true }
  )
  assert(bar.width <= width, ('%d cells in %d: %s'):format(bar.width, width, bar.str))
  return bar.str
end

-- Neovim cuts a winbar too long for its window from the left, which takes the
-- file and the sha first, so the subject gives way instead.
test('session: a long subject is cut to leave the file, the sha and the notes', function()
  local columns = vim.o.columns
  vim.o.columns = 250
  local ok, err = pcall(with_session, long_subject, function(s)
    session.toggle_whitespace(s)
    show_commit(s, 1)
    local commit = s.commits[1]
    local fixed = (' a.lua @ %s'):format(commit.sha)
    local tail = '   [2 files]   -w'
    local wide = drawn_winbar(s, 200)
    eq(fixed .. ' ' .. commit.subject .. tail, wide)

    -- every width down to where only a cell of the subject is left, which
    -- crosses the wide characters at both of their cells
    local least = vim.fn.strdisplaywidth(fixed .. tail) + 2
    for width = vim.fn.strdisplaywidth(wide) - 1, least, -1 do
      local bar = drawn_winbar(s, width)
      local subject = bar:sub(#fixed + 1, #bar - #tail)
      eq(fixed, bar:sub(1, #fixed))
      eq(tail, bar:sub(#bar - #tail + 1))
      assert(subject:find('^ .*…$'), bar)
      local whole = ' ' .. commit.subject
      eq(whole:sub(1, #subject - #'…'), subject:sub(1, #subject - #'…'))
      -- nothing left over but a cell a wide character did not fit in, and a
      -- space dropped before the `…`
      assert(vim.fn.strdisplaywidth(bar) >= width - 2, bar)
    end
  end)
  vim.o.columns = columns
  assert(ok, err)
end)

-- With no room even for the subject, what is cut is the end of the winbar rather
-- than its start, where the file is.
test('session: a winbar too narrow for all but the subject is cut from the right', function()
  with_session(long_subject, function(s)
    session.toggle_whitespace(s)
    show_commit(s, 1)
    local bar = drawn_winbar(s, 20)
    assert(bar:find('^ a.lua @ '), bar)
  end)
end)

--- Run `fn` with the file lists laid out as trees.
--- @param setup fun(repo: gitview.TestRepo)
--- @param fn fun(s: gitview.Session, repo: gitview.TestRepo)
local function with_tree_session(setup, fn)
  local config = require('gitview.config')
  local kept = config.values.list_style
  config.values.list_style = 'tree'
  local ok, err = pcall(with_session, setup, fn)
  config.values.list_style = kept
  if not ok then
    error(err, 0)
  end
end

local function nested(repo)
  repo.write('README.md', { 'one' })
  repo.write('src/a.lua', { 'one' })
  repo.write('src/b.lua', { 'one' })
  repo.commit('init')
  repo.write('README.md', { 'two' })
  repo.write('src/a.lua', { 'two' })
  repo.write('src/b.lua', { 'two' })
end

--- Put the files pane's cursor on a row and follow it, as moving there does.
--- @param s gitview.Session
--- @param row integer
local function files_cursor(s, row)
  vim.api.nvim_set_current_win(s.files_win)
  vim.api.nvim_win_set_cursor(s.files_win, { row, 0 })
  session.follow_cursor(s, s.files_win)
end

-- The rows stay whole paths, so a yanked row still names the file; the tree is
-- drawn over them.
test('session: a tree lists directories between the files, as paths', function()
  with_tree_session(nested, function(s)
    eq({ './', 'README.md', 'src/', 'src/a.lua', 'src/b.lua' }, rows(s))
  end)
end)

-- The first row of a tree is the root, which shows nothing.
test('session: a tree opens on its first file rather than its root', function()
  with_tree_session(nested, function(s)
    eq(2, vim.api.nvim_win_get_cursor(s.files_win)[1])
    eq({ kind = 'file', index = 1 }, s.selected)
  end)
end)

--- Wait for the diff pane to show a view of these files.
--- @param s gitview.Session
--- @param files string[] their labels
local function wait_files(s, files)
  local done = vim.wait(1000, function()
    local view = require('gitview.diff.render').view_of(s.diff_buf)
    return view ~= nil and vim.deep_equal(view_files(s), files)
  end)
  assert(done, table.concat(diff_rows(s), '\n'))
end

-- A directory is many files as a commit is, so it is read in the background.
-- Until the cursor has rested on it, the pane keeps the file it showed.
test('session: a directory row shows the files in it together', function()
  with_tree_session(nested, function(s)
    files_cursor(s, 3)
    eq({ kind = 'dir', index = 2, path = 'src' }, s.selected)
    eq({ 'README.md' }, view_files(s))
    eq(nil, s.pending)
    eq(nil, s.index_lines)
    wait_files(s, { 'src/a.lua', 'src/b.lua' })
  end)
end)

test('session: the root row shows every file', function()
  with_tree_session(nested, function(s)
    files_cursor(s, 1)
    wait_files(s, { 'README.md', 'src/a.lua', 'src/b.lua' })
  end)
end)

-- Moving from file to file passes over directory rows, which are not read
-- unless the cursor stays.
test('session: a directory passed over is never read', function()
  with_tree_session(nested, function(s)
    local source = require('gitview.diff.source')
    local for_entries = source.for_entries
    local reads = 0
    source.for_entries = function(...)
      reads = reads + 1
      return for_entries(...)
    end
    local ok, err = pcall(function()
      files_cursor(s, 3)
      files_cursor(s, 4)
      vim.wait(300)
      eq(0, reads)
      eq({ 'src/a.lua' }, view_files(s))
    end)
    source.for_entries = for_entries
    assert(ok, err)
  end)
end)

-- A refresh redraws what is already on screen, which a placeholder would only
-- blink over.
test('session: a refresh redraws a directory at once', function()
  with_tree_session(nested, function(s, repo)
    files_cursor(s, 3)
    wait_files(s, { 'src/a.lua', 'src/b.lua' })
    repo.write('src/c.lua', { 'new' })
    session.refresh(s)
    settle(s)
    eq(nil, s.pending)
    eq({ 'src/a.lua', 'src/b.lua', 'src/c.lua' }, view_files(s))
  end)
end)

test('session: `]f` and `[f` pass over directory rows', function()
  with_tree_session(nested, function(s)
    press_diff(s, ']f')
    eq(2, selected(s))
    eq(4, vim.api.nvim_win_get_cursor(s.files_win)[1])
    press_diff(s, '[f')
    eq(1, selected(s))
    eq(2, vim.api.nvim_win_get_cursor(s.files_win)[1])
  end)
end)

-- A directory's diff is many files in one buffer, as a commit's is, so the keys
-- move between them there rather than moving the list.
test('session: `]f` and `[f` in a directory\'s diff move between its files', function()
  with_tree_session(nested, function(s)
    files_cursor(s, 3)
    wait_files(s, { 'src/a.lua', 'src/b.lua' })
    local files = diff_view(s).files
    vim.api.nvim_set_current_win(s.diff_win)
    vim.api.nvim_win_set_cursor(s.diff_win, { files[1].row, 0 })
    press_diff(s, ']f')
    eq(files[2].row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
    press_diff(s, '[f')
    eq(files[1].row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
    eq({ kind = 'dir', index = 2, path = 'src' }, s.selected)
    eq(3, vim.api.nvim_win_get_cursor(s.files_win)[1])
  end)
end)

test('session: a directory stays selected across a refresh', function()
  with_tree_session(nested, function(s, repo)
    files_cursor(s, 3)
    repo.write('A.md', { 'new' })
    session.refresh(s)
    settle(s)
    eq({ './', 'A.md', 'README.md', 'src/', 'src/a.lua', 'src/b.lua' }, rows(s))
    eq({ kind = 'dir', index = 3, path = 'src' }, s.selected)
    eq(4, vim.api.nvim_win_get_cursor(s.files_win)[1])
  end)
end)

test('session: a commit looked into lists its files as a tree', function()
  with_tree_session(function(repo)
    repo.write('a.txt', { 'one' })
    repo.commit('init')
    repo.write('lib/x.lua', { 'one' })
    repo.commit('second')
  end, function(s)
    show_commit(s, 1)
    session.enter(s)
    eq({ './', 'lib/', 'lib/x.lua' }, commit_rows(s))
    eq(3, vim.api.nvim_win_get_cursor(s.commits_win)[1])
    eq({ kind = 'commit_file', index = 1 }, s.selected)
  end)
end)

local function committed_dir(repo)
  repo.write('a.txt', { 'one' })
  repo.commit('init')
  repo.write('a.txt', { 'two' })
  repo.write('lib/x.lua', { 'one' })
  repo.write('lib/y.lua', { 'one' })
  repo.commit('second')
end

--- Put the commits pane's cursor on a row and follow it, as moving there does.
--- @param s gitview.Session
--- @param row integer
local function commits_cursor(s, row)
  vim.api.nvim_set_current_win(s.commits_win)
  vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
  session.follow_cursor(s, s.commits_win)
end

-- Looking into a commit has passed over its row, which read the whole commit;
-- a directory of it is taken out of that read rather than read again.
test('session: a directory of a commit is drawn from the commit already read', function()
  with_tree_session(committed_dir, function(s)
    show_commit(s, 1)
    session.enter(s)
    eq({ './', 'a.txt', 'lib/', 'lib/x.lua', 'lib/y.lua' }, commit_rows(s))
    counting_range_reads(function(reads)
      commits_cursor(s, 3)
      eq(nil, s.pending)
      wait_files(s, { 'lib/x.lua', 'lib/y.lua' })
      eq(s.scope.label, diff_view(s).rev)
      commits_cursor(s, 1)
      wait_files(s, { 'a.txt', 'lib/x.lua', 'lib/y.lua' })
      eq(0, reads())
    end)
  end)
end)

-- The root of a commit is its files, as its directories are; the message is
-- on the commit's own row.
test('session: the root of a commit shows no commit header', function()
  with_tree_session(committed_dir, function(s)
    show_commit(s, 1)
    session.enter(s)
    commits_cursor(s, 1)
    wait_files(s, { 'a.txt', 'lib/x.lua', 'lib/y.lua' })
    eq(nil, diff_view(s).header_rows)
  end)
end)

test('session: a directory of a commit not read yet reads the whole commit once', function()
  with_tree_session(committed_dir, function(s)
    show_commit(s, 1)
    session.enter(s)
    s.range_reads, s.range_order = {}, {}
    counting_range_reads(function(reads)
      commits_cursor(s, 3)
      wait_files(s, { 'lib/x.lua', 'lib/y.lua' })
      commits_cursor(s, 1)
      wait_files(s, { 'a.txt', 'lib/x.lua', 'lib/y.lua' })
      eq(1, reads())
    end)
  end)
end)

test('session: `s` and `u` on a directory row take all of its files', function()
  with_tree_session(nested, function(s, repo)
    files_cursor(s, 3)
    press(s, 's')
    eq(' M README.md\nM  src/a.lua\nM  src/b.lua\n', repo.git('status', '--short'))
    -- still on the directory, which still names the same files
    eq({ kind = 'dir', index = 2, path = 'src' }, s.selected)
    press(s, 'u')
    eq(' M README.md\n M src/a.lua\n M src/b.lua\n', repo.git('status', '--short'))
  end)
end)

-- A directory's diff sits among the files, whose diffs take `s` and `u` by
-- row, so it says why it does not rather than doing nothing.
test('session: `s` in the diff of a directory stages nothing and says why', function()
  with_tree_session(nested, function(s, repo)
    files_cursor(s, 3)
    wait_files(s, { 'src/a.lua', 'src/b.lua' })
    local notify = vim.notify
    local messages = {}
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
    local ok, err = pcall(function()
      vim.api.nvim_set_current_win(s.diff_win)
      vim.api.nvim_win_set_cursor(s.diff_win, { changed_row(s, 'two'), 0 })
      press_diff(s, 's')
      press_diff(s, 'S')
    end)
    vim.notify = notify
    assert(ok, err)
    eq(' M README.md\n M src/a.lua\n M src/b.lua\n', repo.git('status', '--short'))
    eq(2, #messages)
    assert(messages[1]:find("single file's diff", 1, true), messages[1])
  end)
end)

test('session: `s` on the root stages everything', function()
  with_tree_session(nested, function(s, repo)
    files_cursor(s, 1)
    press(s, 's')
    eq('M  README.md\nM  src/a.lua\nM  src/b.lua\n', repo.git('status', '--short'))
  end)
end)

-- The tree keeps the entries' order rather than putting directories first, so
-- the files a multi-file diff lists run in the order the files pane shows them.
-- These names are the ones where the two orders part: `-` and `.` sort before
-- `/`, and capitals before lower case.
test('session: a tree lists the files in the order the working-tree diff does', function()
  with_tree_session(function(repo)
    for _, path in ipairs({ 'B.md', 'a-b/y.lua', 'a.lua', 'a/x.lua' }) do
      repo.write(path, { 'one' })
    end
    repo.commit('init')
    for _, path in ipairs({ 'B.md', 'a-b/y.lua', 'a.lua', 'a/x.lua' }) do
      repo.write(path, { 'two' })
    end
  end, function(s)
    local listed = {}
    for row = 1, vim.api.nvim_buf_line_count(s.files_buf) do
      local target = list.target_at(s.files_buf, row)
      if target and target.kind == 'file' then
        listed[#listed + 1] = s.entries[target.index].path
      end
    end
    eq({ 'B.md', 'a-b/y.lua', 'a.lua', 'a/x.lua' }, listed)
    goto_worktree(s)
    session.show_selected(s)
    eq(listed, view_files(s))
  end)
end)

local CONFLICT = { '<<<<<<< HEAD', 'ours', '=======', 'theirs', '>>>>>>> other' }

test('session: a conflicted file is shown as its working tree has it', function()
  with_session(mid_merge, function(s)
    eq({ 'fight.txt' }, rows(s))
    eq(true, s.entries[1].conflicted)
    eq(vim.list_extend({ 'fight.txt' }, CONFLICT), diff_rows(s))
    -- the header counts conflicts where it would count lines
    local header = diff_gutter(s, 1)
    assert(header:find('%#GitViewFileHeaderConflictCount#!1 ', 1, true), header)
    -- only the working tree's line numbers, markers included
    eq('     %#GitViewNewLnum#   1   ', diff_gutter(s, 2))
    eq('     %#GitViewNewLnum#   4   ', diff_gutter(s, 5))
    -- The index has no stage 0 to stage rows into.
    eq(nil, s.index_lines)
  end)
end)

test('session: `gf` in a conflict opens the file at that line', function()
  with_session(mid_merge, function(s)
    vim.api.nvim_win_set_cursor(s.diff_win, { row_of_text(s, 'theirs', 'conflict'), 0 })
    eq({ 'fight.txt', 4 }, { press_gf(s, s.diff_win) })
  end)
end)

--- Leave the repository mid-merge with a file one side deleted and the other
--- changed, which leaves the changed side in the working tree with no markers.
--- @param repo gitview.TestRepo
local function mid_merge_deleted(repo)
  repo.write('gone.txt', { 'base' })
  repo.commit('init')
  repo.git('checkout', '-q', '-b', 'other')
  repo.git('rm', '-q', 'gone.txt')
  repo.commit('deleted')
  repo.git('checkout', '-q', '-')
  repo.write('gone.txt', { 'ours' })
  repo.commit('ours')
  vim.system({ 'git', 'merge', 'other' }, { cwd = repo.root, text = true }):wait()
end

test('session: a conflict with no markers says how to resolve it', function()
  with_session(mid_merge_deleted, function(s)
    eq(true, s.entries[1].conflicted)
    eq({ 'gone.txt   (unresolved conflict with no markers; staging the file marks it resolved)' }, diff_rows(s))
  end)
end)

test('session: a directory shows its conflicted files among the others', function()
  with_tree_session(function(repo)
    repo.write('calm.txt', { 'one' })
    mid_merge(repo)
    repo.write('calm.txt', { 'two' })
  end, function(s)
    files_cursor(s, 1)
    wait_files(s, { 'calm.txt', 'fight.txt' })
    local view = assert(require('gitview.diff.render').view_of(s.diff_buf))
    eq(1, view.files[2].conflicts)
    local rows_ = diff_rows(s)
    eq(CONFLICT, vim.list_slice(rows_, #rows_ - 4))
    -- `]c` stops at the conflict as at a hunk
    eq(view.files[2].row + 1, view.hunk_rows[#view.hunk_rows])
  end)
end)

--- Twenty numbered lines, with some of them replaced.
--- @param changed table<integer, string>?
--- @return string[]
local function numbered(changed)
  local lines = {}
  for i = 1, 20 do
    lines[i] = (changed or {})[i] or ('line ' .. i)
  end
  return lines
end

--- A file staged only, one unstaged only, one with both, and an untracked one.
local function layered(repo)
  repo.write('both.txt', { 'one' })
  repo.write('staged.txt', { 'one' })
  repo.write('work.txt', { 'one' })
  repo.commit('init')
  repo.write('both.txt', { 'two' })
  repo.write('staged.txt', { 'two' })
  repo.git('add', 'both.txt', 'staged.txt')
  repo.write('both.txt', { 'three' })
  repo.write('work.txt', { 'two' })
  repo.write('loose.txt', { 'new' })
end

--- @param s gitview.Session
--- @return string
local function files_winbar(s)
  vim.g.statusline_winid = s.files_win
  return (list.winbar():gsub('%%#%w+#', ''))
end

--- The kind and text of the diff row under the cursor.
--- @param s gitview.Session
--- @return string
local function cursor_line(s)
  local view = assert(require('gitview.diff.render').view_of(s.diff_buf), 'no view drawn')
  local l = view.lines[vim.api.nvim_win_get_cursor(s.diff_win)[1]]
  return ('%s %s'):format(l.kind, l.text)
end

test('session: `gs` goes through both layers, staged alone and unstaged alone', function()
  with_session(layered, function(s)
    local name = vim.fs.basename(s.root)
    eq({ 'both.txt', 'loose.txt', 'staged.txt', 'work.txt' }, rows(s))
    eq((' %s   4 files'):format(name), files_winbar(s))
    eq(' HEAD, staged + unstaged', diff_winbar(s))
    press(s, 'gs')
    eq({ 'both.txt', 'staged.txt' }, rows(s))
    eq((' %s   2 staged'):format(name), files_winbar(s))
    eq(' HEAD, staged', diff_winbar(s))
    press(s, 'gs')
    -- an untracked file is unstaged only
    eq({ 'both.txt', 'loose.txt', 'work.txt' }, rows(s))
    eq((' %s   3 unstaged'):format(name), files_winbar(s))
    eq(' index, unstaged', diff_winbar(s))
    press(s, 'gs')
    eq({ 'both.txt', 'loose.txt', 'staged.txt', 'work.txt' }, rows(s))
  end)
end)

test('session: a layer alone shows that change of a file alone', function()
  with_session(layered, function(s)
    press(s, 'gs')
    eq({ 'both.txt', 'one', 'two' }, diff_rows(s))
    press(s, 'gs')
    eq({ 'both.txt', 'two', 'three' }, diff_rows(s))
  end)
end)

-- An unmerged file's index has no version a commit would take, and resolving
-- it is deciding what to stage.
test('session: an unmerged file is listed unstaged and not staged', function()
  with_session(mid_merge, function(s)
    press(s, 'gs')
    eq({ 'nothing staged' }, rows(s))
    eq({ 'nothing staged' }, diff_rows(s))
    press(s, 'gs')
    eq({ 'fight.txt' }, rows(s))
  end)
end)

test('session: switching layers keeps the file and the line the cursor is on', function()
  with_session(function(repo)
    repo.write('f.txt', numbered())
    repo.commit('init')
    repo.write('f.txt', numbered({ [19] = 'NINETEEN' }))
    repo.git('add', 'f.txt')
    repo.write('f.txt', numbered({ [2] = 'TWO', [19] = 'NINETEEN' }))
  end, function(s)
    put_cursor(s, changed_row(s, 'NINETEEN'))
    press_diff(s, 'gs')
    eq('add NINETEEN', cursor_line(s))
    press_diff(s, 'gs')
    -- unchanged from the index to the working tree
    eq('context NINETEEN', cursor_line(s))
    press_diff(s, 'gs')
    eq('add NINETEEN', cursor_line(s))
  end)
end)

test('session: switching to a layer without the file selects the first file', function()
  with_session(function(repo)
    repo.write('a.txt', { 'one' })
    repo.write('b.txt', numbered())
    repo.commit('init')
    repo.write('a.txt', { 'two' })
    repo.git('add', 'a.txt')
    repo.write('b.txt', numbered({ [19] = 'NINETEEN' }))
  end, function(s)
    session.select(s, 2)
    put_cursor(s, changed_row(s, 'NINETEEN'))
    press_diff(s, 'gs')
    eq('a.txt', s.entries[selected(s)].path)
    eq(1, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  end)
end)

test('session: the diff refuses to stage what its layer does not show', function()
  with_session(layered, function(s, repo)
    press(s, 'gs')
    local before = repo.git('status', '--short')
    put_cursor(s, changed_row(s, 'two'))
    eq({ 'gitview: only staged changes are shown' }, notified(function()
      press_diff(s, 's')
    end))
    eq({ 'gitview: only staged changes are shown' }, notified(function()
      press_diff(s, 'S')
    end))
    press(s, 'gs')
    put_cursor(s, changed_row(s, 'three'))
    eq({ 'gitview: only unstaged changes are shown' }, notified(function()
      press_diff(s, 'u')
    end))
    eq(before, repo.git('status', '--short'))
  end)
end)

-- Staging from a layer alone takes the rows out of it, so the cursor goes on to
-- what is left rather than keeping a row that is now another line.
test('session: staging from a layer alone moves on through the changes', function()
  with_session(function(repo)
    repo.write('f.txt', numbered())
    repo.write('g.txt', { 'one' })
    repo.commit('init')
    repo.write('f.txt', numbered({ [2] = 'TWO', [19] = 'NINETEEN' }))
    repo.write('g.txt', { 'two' })
  end, function(s)
    press(s, 'gsgs')
    put_cursor(s, changed_row(s, 'TWO'))
    press_diff(s, 's')
    -- what is left of the change, from its start
    eq('del line 2', cursor_line(s))
    press_diff(s, 's')
    -- the change is gone, so on to the next one in the file
    eq('del line 19', cursor_line(s))
    press_diff(s, 'S')
    -- and with the file's last change gone, so is the file: the next one is
    -- shown from its header, so that `s` pressed again does nothing
    eq('g.txt', s.entries[selected(s)].path)
    eq(1, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  end)
end)

test('session: staging the last change of a layer alone leaves the cursor', function()
  with_session(function(repo)
    repo.write('f.txt', numbered())
    repo.commit('init')
    repo.write('f.txt', numbered({ [2] = 'TWO', [19] = 'NINETEEN' }))
  end, function(s)
    press(s, 'gsgs')
    put_cursor(s, changed_row(s, 'NINETEEN'))
    press_diff(s, 'S')
    eq({ 'gitview: nothing to stage here' }, notified(function()
      press_diff(s, 's')
    end))
  end)
end)

test('session: a layer alone keeps the line when the index changes under it', function()
  with_session(function(repo)
    repo.write('f.txt', numbered())
    repo.commit('init')
    repo.write('f.txt', numbered({ [19] = 'NINETEEN' }))
    repo.git('add', 'f.txt')
    repo.write('f.txt', numbered({ [2] = 'TWO', [19] = 'NINETEEN' }))
  end, function(s, repo)
    press(s, 'gs')
    put_cursor(s, changed_row(s, 'NINETEEN'))
    repo.git('add', 'f.txt')
    session.refresh(s)
    settle(s)
    eq('add NINETEEN', cursor_line(s))
  end)
end)

-- A directory's row stands for what is on screen under it.
test("session: a directory's `s` in a layer alone takes only the files listed", function()
  with_tree_session(function(repo)
    repo.write('src/a.lua', { 'one' })
    repo.write('src/b.lua', { 'one' })
    repo.commit('init')
    repo.write('src/a.lua', { 'two' })
    repo.git('add', 'src/a.lua')
    repo.write('src/a.lua', { 'three' })
    repo.write('src/b.lua', { 'two' })
  end, function(s, repo)
    press(s, 'gs')
    eq({ './', 'src/', 'src/a.lua' }, rows(s))
    files_cursor(s, 2)
    press(s, 's')
    eq('M  src/a.lua\n M src/b.lua\n', repo.git('status', '--short'))
  end)
end)

test('session: the working-tree row shows the layer the list does', function()
  with_session(layered, function(s)
    press(s, 'gs')
    goto_worktree(s)
    session.show_selected(s)
    eq({ 'both.txt', 'staged.txt' }, view_files(s))
    eq(' HEAD, staged   [2 files]', diff_winbar(s))
  end)
end)
