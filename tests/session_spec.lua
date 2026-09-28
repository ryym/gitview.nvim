local list = require('unidiff.ui.list')
local session = require('unidiff.ui.session')
local helpers = dofile('tests/helpers.lua')

local test, eq = _G.test, _G.eq

--- Open a session against a fresh repository, run `fn`, then close it.
---
--- `:lcd` into the repository is what makes the session find it, the same way
--- the commands do for the buffer they were called from.
--- @param setup fun(repo: unidiff.TestRepo)
--- @param fn fun(s: unidiff.Session, repo: unidiff.TestRepo)
local function with_session(setup, fn)
  helpers.with_repo(function(repo)
    setup(repo)
    local previous = vim.fn.getcwd()
    vim.cmd.lcd(repo.root)
    local s = session.open()
    local ok, err = pcall(function()
      assert(s, 'no session opened')
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
--- @param s unidiff.Session
--- @return string[]
local function rows(s)
  return vim.api.nvim_buf_get_lines(s.files_buf, 0, -1, false)
end

--- The commits pane, which holds the commit list or, inside one, its files.
--- @param s unidiff.Session
--- @return string[]
local function commit_rows(s)
  return vim.api.nvim_buf_get_lines(s.commits_buf, 0, -1, false)
end

--- Which file is selected, for the tests that only care about that.
--- @param s unidiff.Session
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
    eq(s.root, list.state[s.files_buf].root)
  end)
end)

test('session: is registered against its own tab page', function()
  with_session(base, function(s)
    eq(s, session.sessions[s.tab])
    eq(s, session.current())
  end)
end)

test('session: refreshing picks up changes made since', function()
  with_session(base, function(s, repo)
    repo.git('add', 'loose.txt')
    repo.write('third.txt', { 'more' })
    session.refresh(s)
    eq({ 'edit.txt', 'loose.txt', 'third.txt' }, rows(s))
    eq('A', s.entries[2].index_status)
  end)
end)

test('session: an automatic refresh picks up changes made since', function()
  with_session(base, function(s, repo)
    repo.write('third.txt', { 'more' })
    session.refresh(s, { auto = true })
    eq({ 'edit.txt', 'loose.txt', 'third.txt' }, rows(s))
  end)
end)

-- `TabEnter` fires on every move between tab pages, so an automatic refresh has
-- to be cheap to trigger. What the user asks for is never held back.
test('session: an automatic refresh is throttled and a manual one is not', function()
  with_session(base, function(s, repo)
    session.refresh(s, { auto = true })
    repo.write('third.txt', { 'more' })
    session.refresh(s, { auto = true })
    eq({ 'edit.txt', 'loose.txt' }, rows(s))
    session.refresh(s)
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
    local status = require('unidiff.status')
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
      eq({}, messages)
      session.refresh(s)
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

-- Closing the tab any other way has to clean up just the same, or the session
-- outlives what it was drawn in.
test('session: closing the tab directly drops the session', function()
  with_session(base, function(s)
    local tab = s.tab
    vim.cmd.tabclose()
    eq(nil, session.sessions[tab])
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
    eq({ 'UnidiffStatusStaged', 'UnidiffStatusUnstaged' }, groups)

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
    for _, key in ipairs({ 'R', 'o', 'q' }) do
      assert(lhs[key], 'no mapping for ' .. key)
    end
  end)
end)

test('session: opening an entry replaces the session with the file', function()
  with_session(base, function(s)
    vim.api.nvim_win_set_cursor(s.files_win, { 2, 0 }) -- loose.txt
    local tab = s.tab
    session.edit_entry(s)
    eq(nil, session.sessions[tab])
    eq(s.root .. '/loose.txt', vim.api.nvim_buf_get_name(0))
  end)
end)

-- A staged deletion has no working copy to open, and `:edit` would make an
-- empty buffer for it as if the file were new.
test('session: a file the working tree lacks is not opened', function()
  with_session(function(repo)
    repo.write('gone.txt', { 'x' })
    repo.commit('init')
    repo.git('rm', '-q', 'gone.txt')
  end, function(s)
    local before = vim.api.nvim_get_current_buf()
    session.edit_entry(s)
    eq(before, vim.api.nvim_get_current_buf())
    assert(session.sessions[s.tab], 'the session should still be open')
  end)
end)

--- @param s unidiff.Session
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
    for _, l in ipairs(require('unidiff.diff.render').view_of(s.diff_buf).lines) do
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
    eq(nil, require('unidiff.diff.render').view_of(s.diff_buf))
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
    eq(1, selected(s))
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('return 4', 1, true), text)
  end)
end)

test('session: the diff pane takes what the list leaves', function()
  with_session(two, function(s)
    local width = require('unidiff.config').values.list_width
    eq(width, vim.api.nvim_win_get_width(s.files_win))
    eq(width, vim.api.nvim_win_get_width(s.commits_win))
    assert(vim.api.nvim_win_get_width(s.diff_win) > 0, 'the diff pane has no width')
    eq(true, vim.wo[s.files_win].winfixwidth)
    -- the files pane absorbs a resize; the commit list keeps its height
    eq(true, vim.wo[s.commits_win].winfixheight)
    eq(false, vim.wo[s.files_win].winfixheight)
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

--- Press a key in one of the sidebar panes, so that the buffer-local mapping is
--- what is being tested rather than the function behind it.
--- @param s unidiff.Session
--- @param key string
--- @param win integer? which pane; the files pane by default
local function press(s, key, win)
  vim.api.nvim_set_current_win(win or s.files_win)
  vim.cmd.normal(key)
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
    eq(true, s.has_head)
  end)
end)

test('session: staging a file with nothing unstaged changes nothing', function()
  with_session(base, function(s, repo)
    repo.git('add', 'edit.txt')
    session.refresh(s)
    session.select(s, 1)
    press(s, 's')
    eq('M  edit.txt\n?? loose.txt\n', repo.git('status', '--short'))
  end)
end)

--- Press a key in the diff pane, where `s` and `u` work on lines rather than on
--- the whole file. Mappings are applied, so the mapping is what is tested.
--- @param s unidiff.Session
--- @param keys string
local function press_diff(s, keys)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.cmd.normal(keys)
end

--- The diff row a changed line of this text is drawn on.
--- @param s unidiff.Session
--- @param text string
--- @return integer
local function changed_row(s, text)
  local view = assert(require('unidiff.diff.render').view_of(s.diff_buf), 'no view drawn')
  for i, l in ipairs(view.lines) do
    if l.text == text and l.stage then
      return i
    end
  end
  error('no changed row reading ' .. text)
end

--- @param s unidiff.Session
--- @param row integer
local function put_cursor(s, row)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
end

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
    local view = require('unidiff.diff.render').view_of(s.diff_buf)
    eq('staged', view.lines[changed_row(s, 'six')].stage)
  end)
end)

test('session: a row with nothing to stage leaves the index alone', function()
  with_session(partial, function(s, repo)
    -- `three` is unchanged in all three versions, so it is a context row.
    local view = require('unidiff.diff.render').view_of(s.diff_buf)
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
--- @param repo unidiff.TestRepo
local function mid_merge(repo)
  repo.write('fight.txt', { 'base' })
  repo.commit('init')
  repo.git('checkout', '-q', '-b', 'other')
  repo.write('fight.txt', { 'theirs' })
  repo.commit('theirs')
  repo.git('checkout', '-q', '-')
  repo.write('fight.txt', { 'ours' })
  repo.commit('ours')
  -- The merge is meant to fail, so its exit code is not checked.
  vim.system({ 'git', 'merge', 'other' }, { cwd = repo.root, text = true }):wait()
end

test('session: a conflicted file says so instead of showing a diff', function()
  with_session(mid_merge, function(s)
    eq({ 'fight.txt' }, rows(s))
    eq(true, s.entries[1].conflicted)
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('unresolved conflict', 1, true), text)
    -- Nothing was drawn, so nothing can be staged from it by row.
    eq(nil, s.index_lines)
  end)
end)

-- Writing a stage-0 entry over a conflict's merge stages discards them and git
-- reports no error, so the row-level keys have to refuse outright.
test('session: `s` in the diff leaves a conflict alone', function()
  with_session(mid_merge, function(s, repo)
    local before = repo.git('ls-files', '-u')
    assert(before ~= '', 'the merge stages should be there to begin with')
    vim.api.nvim_set_current_win(s.diff_win)
    vim.cmd.normal('s')
    vim.cmd.normal('u')
    vim.cmd.normal('S')
    eq(before, repo.git('ls-files', '-u'))
    eq('UU fight.txt\n', repo.git('status', '--short'))
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

--- Put the cursor on a commit row and draw it. `sync_selection` defers a commit
--- so that sweeping the list does not build one view per row; the tests assert
--- what is drawn, not when.
--- @param s unidiff.Session
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
    eq({ shas[1] .. ' second', shas[2] .. ' first' }, commit_rows(s))
    eq({ kind = 'commit', index = 1 }, list.target_at(s.commits_buf, 1))
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
    eq('commit', s.selected.kind)
    vim.api.nvim_set_current_win(s.files_win)
    eq('file', s.selected.kind)
  end)
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
    local view = require('unidiff.diff.render').view_of(s.diff_buf)
    assert(view, 'the root commit should have a view')
    for _, l in ipairs(view.lines) do
      if require('unidiff.diff.lines').source_kinds[l.kind] then
        eq('add', l.kind)
      end
    end
  end)
end)

-- Its line numbers are the commit's. Jumping would land on whatever now
-- occupies that line in the working tree.
test('session: a commit view is marked historical and is not mixed', function()
  with_session(history, function(s)
    show_commit(s, 1)
    local view = require('unidiff.diff.render').view_of(s.diff_buf)
    eq(true, view.historical)
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
    local view = require('unidiff.diff.render').view_of(s.diff_buf)
    eq(1, #view.files)
    eq('a.lua', view.files[1].label)
    eq(true, view.historical)
    local text = table.concat(diff_rows(s), '\n')
    assert(text:find('return 1', 1, true), text)
    assert(text:find('return 2', 1, true), text)
    -- the working tree's version is not one of the two being compared
    assert(not text:find('return 3', 1, true), text)
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
--- @param s unidiff.Session
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
    eq('staged', require('unidiff.diff.render').view_of(s.diff_buf).lines[row].stage)
    eq(row, diff_row(s))
  end)
end)

test('session: a refresh that changes nothing keeps the position in the diff', function()
  with_session(long_history, function(s)
    session.select(s, 1)
    vim.api.nvim_win_set_cursor(s.diff_win, { 25, 0 })
    session.refresh(s)
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
--- @param s unidiff.Session
--- @param index integer
local function goto_commit(s, index)
  local row = assert(list.row_of(s.commits_buf, { kind = 'commit', index = index }))
  vim.api.nvim_win_set_cursor(s.commits_win, { row, 0 })
  s.selected = { kind = 'commit', index = index }
end

--- @param s unidiff.Session
--- @return string
local function diff_winbar(s)
  vim.g.statusline_winid = s.diff_win
  return (require('unidiff.diff.render').winbar():gsub('%%#%w+#', ''))
end

test('session: the marked commit is shown in the gutter', function()
  with_session(forked_history, function(s)
    goto_commit(s, 3)
    session.toggle_mark(s)
    eq(s.commits[3].sha, s.mark)
    eq('%#UnidiffStatusMark#>  ', list.state[s.commits_buf].rows[3].gutter)
    eq(nil, list.state[s.commits_buf].rows[2].gutter)
  end)
end)

test('session: marking the marked commit again clears it', function()
  with_session(forked_history, function(s)
    goto_commit(s, 2)
    session.toggle_mark(s)
    session.toggle_mark(s)
    eq(nil, s.mark)
    eq(nil, list.state[s.commits_buf].rows[2].gutter)
  end)
end)

-- The list is newest first, so which of the two is the old side follows from
-- where they sit rather than from their dates.
test('session: a mark and the cursor compare the stretch between them', function()
  with_session(forked_history, function(s)
    goto_commit(s, 4)
    session.toggle_mark(s)
    goto_commit(s, 1)
    session.show_selected(s)
    local label = ('%s..%s'):format(s.commits[4].sha, s.commits[1].sha)
    assert(diff_winbar(s):find(label, 1, true), diff_winbar(s))
    -- first -> merge side adds both branches' files
    eq({ 'main.txt', 'side.txt' }, vim.tbl_map(function(f)
      return f.label
    end, require('unidiff.diff.render').view_of(s.diff_buf).files))
  end)
end)

test('session: marking in the other direction gives the same range', function()
  with_session(forked_history, function(s)
    goto_commit(s, 1)
    session.toggle_mark(s)
    goto_commit(s, 4)
    session.show_selected(s)
    local label = ('%s..%s'):format(s.commits[4].sha, s.commits[1].sha)
    assert(diff_winbar(s):find(label, 1, true), diff_winbar(s))
  end)
end)

-- The cursor on the mark itself is not a range of nothing; it is the one commit.
test('session: the cursor on the mark shows that commit alone', function()
  with_session(forked_history, function(s)
    goto_commit(s, 2)
    session.toggle_mark(s)
    session.show_selected(s)
    local commit = s.commits[2]
    assert(diff_winbar(s):find(commit.sha .. ' ' .. commit.subject, 1, true), diff_winbar(s))
  end)
end)

-- `git diff` compares the two trees whatever their history, but across a fork
-- the result also undoes what the other side did, so it is named rather than
-- refused.
test('session: a range across a fork says it is not one line of history', function()
  with_session(forked_history, function(s)
    -- 2 is `on main` and 3 is `on side`: the two branch tips
    goto_commit(s, 3)
    session.toggle_mark(s)
    goto_commit(s, 2)
    session.show_selected(s)
    assert(diff_winbar(s):find('diverged', 1, true), diff_winbar(s))
  end)
end)

test('session: a range along one line of history says nothing extra', function()
  with_session(forked_history, function(s)
    goto_commit(s, 4)
    session.toggle_mark(s)
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
    end, require('unidiff.diff.render').view_of(s.diff_buf).files))
  end)
end)

test('session: looking into a range lists the files it changed', function()
  with_session(forked_history, function(s)
    goto_commit(s, 4)
    session.toggle_mark(s)
    goto_commit(s, 1)
    session.show_selected(s)
    session.enter(s)
    eq(('%s..%s'):format(s.commits[4].sha, s.commits[1].sha), s.scope.label)
    eq({ 'main.txt', 'side.txt' }, commit_rows(s))
    session.show_selected(s)
    eq('main.txt', require('unidiff.diff.render').view_of(s.diff_buf).files[1].label)
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
  local config = require('unidiff.config')
  local kept = config.values.commit_count
  config.values.commit_count = n
  local ok, err = pcall(fn)
  config.values.commit_count = kept
  assert(ok, err)
end

--- @param s unidiff.Session
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
    session.toggle_mark(s)
    -- the cursor moves off the mark, so the list itself can be replaced
    goto_commit(s, 1)
    with_commit_count(2, function()
      session.refresh(s)
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

--- A file whose working tree differs from HEAD in whitespace on one line and in
--- earnest on another.
local function whitespace(repo)
  repo.write('a.txt', { 'a', 'b', 'c' })
  repo.commit('init')
  repo.write('a.txt', { 'a', '  b  ', 'C' })
end

--- @param s unidiff.Session
--- @return string[] the text of every row standing for a source line
local function source_rows(s)
  local view = assert(require('unidiff.diff.render').view_of(s.diff_buf), 'no view drawn')
  local out = {}
  for _, l in ipairs(view.lines) do
    if require('unidiff.diff.lines').source_kinds[l.kind] then
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
    assert(not diff_winbar(s):find('whitespace', 1, true), diff_winbar(s))
    session.toggle_whitespace(s)
    assert(diff_winbar(s):find('(whitespace ignored)', 1, true), diff_winbar(s))
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

--- @param s unidiff.Session
--- @return unidiff.View
local function diff_view(s)
  return assert(require('unidiff.diff.render').view_of(s.diff_buf))
end

--- @param s unidiff.Session
--- @return integer? first row of the closed fold over row 1, nil when open
local function header_closed(s)
  return vim.api.nvim_win_call(s.diff_win, function()
    local row = vim.fn.foldclosed(1)
    return row ~= -1 and vim.fn.foldclosedend(1) or nil
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
    local dlib = require('unidiff.diff.lines')
    for _, r in ipairs(view.hunk_rows) do
      assert(dlib.source_kinds[view.lines[r].kind], 'hunk row ' .. r)
    end
  end)
end)

test('session: the stat graph is colored as git colors it', function()
  with_session(described_history, function(s)
    show_commit(s, 1)
    local ns = vim.api.nvim_create_namespace('unidiff.diff')
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
    eq({ { 11, 12, 'UnidiffStatAdd' }, { 12, 13, 'UnidiffStatDelete' } }, got)
  end)
end)

-- The diff pane is not the current window when a commit is drawn, and
-- 'foldexpr' still has to read the diff's view rather than the current
-- window's.
test('session: the header starts folded, and reads as its subject', function()
  with_session(described_history, function(s)
    show_commit(s, 1)
    assert(vim.api.nvim_get_current_win() ~= s.diff_win)
    eq(10, header_closed(s))
    local text = vim.api.nvim_win_call(s.diff_win, function()
      return require('unidiff.diff.render').foldtext()
    end)
    eq({
      { '\u{25b8} second', 'UnidiffCommitSubject' },
      { '   2 files', 'UnidiffCommitAuthor' },
      { ' +3', 'UnidiffStatAdd' },
      { ' -1', 'UnidiffStatDelete' },
    }, text)
  end)
end)

-- Replacing the lines under an open fold closes it or not depending on how its
-- extent changed, so what the reader chose is carried over explicitly.
test('session: an opened header stays open from one commit to the next', function()
  with_session(described_history, function(s)
    show_commit(s, 1)
    vim.api.nvim_win_call(s.diff_win, function()
      vim.cmd('normal! zo')
    end)
    -- the root commit's header is shorter
    show_commit(s, 2)
    eq(nil, header_closed(s))
    show_commit(s, 1)
    eq(nil, header_closed(s))

    vim.api.nvim_win_call(s.diff_win, function()
      vim.cmd('normal! zc')
    end)
    show_commit(s, 2)
    eq(5, header_closed(s))
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
    session.toggle_mark(s)
    goto_commit(s, 1)
    session.show_selected(s)
    eq(nil, diff_view(s).header_rows)
    eq('a.lua', diff_rows(s)[1])
    -- nothing is folded where there is no header
    eq(nil, header_closed(s))

    goto_commit(s, 2)
    session.show_selected(s)
    eq(10, diff_view(s).header_rows)

    -- the cursor on the mark is the one commit again
    goto_commit(s, 3)
    session.show_selected(s)
    eq(5, diff_view(s).header_rows)

    -- one file of a commit
    session.toggle_mark(s)
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
    vim.api.nvim_win_set_cursor(s.diff_win, { 12, 0 })
    assert(diff_winbar(s):find('^ a.lua @ '), diff_winbar(s))
  end)
end)
