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

--- The file section of the list. The commit section below it, and the blank
--- row separating the two, have tests of their own.
--- @param s unidiff.Session
--- @return string[]
local function rows(s)
  local out = {}
  for _, r in ipairs(list.state[s.list_buf].rows) do
    if r.header then
      break
    end
    if r.text ~= '' then
      out[#out + 1] = r.text
    end
  end
  return out
end

--- Every row of the list, whatever it stands for.
--- @param s unidiff.Session
--- @return string[]
local function rows_all(s)
  return vim.api.nvim_buf_get_lines(s.list_buf, 0, -1, false)
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
    eq(s.root, list.state[s.list_buf].root)
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

-- A refresh usually shortens the file section, and the cursor must not be left
-- past the end of the buffer, nor on one of the rows that stand for nothing.
test('session: refreshing pulls the cursor back inside the list', function()
  with_session(base, function(s, repo)
    vim.api.nvim_win_set_cursor(s.list_win, { 2, 0 })
    repo.git('checkout', '--', 'edit.txt')
    vim.fn.delete(s.root .. '/loose.txt')
    session.refresh(s)
    eq({ list.EMPTY_NOTICE }, rows(s))
    eq(1, vim.api.nvim_win_get_cursor(s.list_win)[1])
  end)
end)

test('session: a clean repository shows the notice and no entries', function()
  with_session(function(repo)
    repo.write('a.txt', { 'x' })
    repo.commit('init')
  end, function(s)
    eq({ list.EMPTY_NOTICE }, rows(s))
    eq({}, s.entries)
    eq(nil, list.entry_at(s.list_buf, 1))
  end)
end)

test('session: closing drops the session and its buffer', function()
  with_session(base, function(s)
    local buf, tab = s.list_buf, s.tab
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
    local win = s.list_win
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
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(s.list_buf, 'n')) do
      lhs[m.lhs] = true
    end
    for _, key in ipairs({ 'R', 'o', 'q' }) do
      assert(lhs[key], 'no mapping for ' .. key)
    end
  end)
end)

test('session: opening an entry replaces the session with the file', function()
  with_session(base, function(s)
    vim.api.nvim_win_set_cursor(s.list_win, { 2, 0 }) -- loose.txt
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
    for _, l in ipairs(require('unidiff.diff.render').views[s.diff_buf].lines) do
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
    vim.api.nvim_set_current_win(s.list_win)
    vim.api.nvim_win_set_cursor(s.list_win, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.list_buf })
    eq(2, selected(s))
    eq({ 'b.lua', 'return 9' }, diff_rows(s))
  end)
end)

test('session: selecting past either end stays on the last file', function()
  with_session(two, function(s)
    session.select(s, 99)
    eq(2, selected(s))
    eq(2, vim.api.nvim_win_get_cursor(s.list_win)[1])
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
    eq(nil, require('unidiff.diff.render').views[s.diff_buf])
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
    eq(width, vim.api.nvim_win_get_width(s.list_win))
    assert(vim.api.nvim_win_get_width(s.diff_win) > 0, 'the diff pane has no width')
    eq(true, vim.wo[s.list_win].winfixwidth)
  end)
end)

test('session: both buffers go when the session closes', function()
  with_session(two, function(s)
    local list_buf, diff_buf = s.list_buf, s.diff_buf
    session.close(s)
    eq(false, vim.api.nvim_buf_is_valid(list_buf))
    eq(false, vim.api.nvim_buf_is_valid(diff_buf))
  end)
end)

--- Press a key in the list window, so that the buffer-local mapping is what is
--- being tested rather than the function behind it.
--- @param s unidiff.Session
--- @param key string
local function press(s, key)
  vim.api.nvim_set_current_win(s.list_win)
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
  local view = assert(require('unidiff.diff.render').views[s.diff_buf], 'no view drawn')
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
    local view = require('unidiff.diff.render').views[s.diff_buf]
    eq('staged', view.lines[changed_row(s, 'six')].stage)
  end)
end)

test('session: a row with nothing to stage leaves the index alone', function()
  with_session(partial, function(s, repo)
    -- `three` is unchanged in all three versions, so it is a context row.
    local view = require('unidiff.diff.render').views[s.diff_buf]
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
  local row = assert(list.row_of(s.list_buf, { kind = 'commit', index = index }))
  vim.api.nvim_win_set_cursor(s.list_win, { row, 0 })
  s.selected = { kind = 'commit', index = index }
  session.show_selected(s)
end

test('session: lists the recent commits below the files', function()
  with_session(history, function(s)
    eq({ 'second', 'first' }, vim.tbl_map(function(c)
      return c.subject
    end, s.commits))
    local rows = list.state[s.list_buf].rows
    eq('a.lua', rows[1].text)
    eq(list.COMMITS_HEADER, rows[3].text)
    eq({ kind = 'commit', index = 1 }, rows[4].target)
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
    local view = require('unidiff.diff.render').views[s.diff_buf]
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
    local view = require('unidiff.diff.render').views[s.diff_buf]
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
    press(s, 's')
    press(s, 'u')
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
    eq('second', s.scope.commit.subject)
    eq({ 'a.lua', 'added.lua' }, vim.tbl_map(function(c)
      return c.path
    end, s.scope.changes))
    -- the header names the commit, and the files replace the whole list
    eq({ s.commits[1].sha .. ' second', 'a.lua', 'added.lua' }, rows_all(s))
    -- the first file is selected, so the pane shows it rather than nothing
    eq({ kind = 'commit_file', index = 1 }, s.selected)
  end)
end)

test('session: a file of a commit is shown by itself', function()
  with_session(history, function(s)
    show_commit(s, 1)
    session.enter(s)
    session.show_selected(s)
    local view = require('unidiff.diff.render').views[s.diff_buf]
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
    eq('second', s.scope.commit.subject)
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
    press(s, 's')
    press(s, 'u')
    eq(before, repo.git('status', '--short'))
  end)
end)
