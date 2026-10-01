local git = require('gitview.git')
local helpers = dofile('tests/helpers.lua')

local test, eq = _G.test, _G.eq

--- `git diff --name-status -z` emits NUL-separated records.
local function z(...)
  return table.concat({ ... }, '\0') .. '\0'
end

test('parses ordinary statuses', function()
  eq({
    { status = 'M', path = 'a.txt', old_path = 'a.txt', binary = false },
    { status = 'A', path = 'b.txt', old_path = 'b.txt', binary = false },
    { status = 'D', path = 'c.txt', old_path = 'c.txt', binary = false },
  }, git.parse_name_status(z('M', 'a.txt', 'A', 'b.txt', 'D', 'c.txt')))
end)

test('parses renames as three records', function()
  -- The status carries a similarity score and the two paths follow it.
  eq({
    { status = 'R', path = 'new.txt', old_path = 'old.txt', binary = false },
    { status = 'M', path = 'z.txt', old_path = 'z.txt', binary = false },
  }, git.parse_name_status(z('R100', 'old.txt', 'new.txt', 'M', 'z.txt')))
end)

test('keeps paths containing spaces intact', function()
  local changes = git.parse_name_status(z('M', 'dir with space/sp ace.txt'))
  eq('dir with space/sp ace.txt', changes[1].path)
end)

test('parses an empty diff', function()
  eq({}, git.parse_name_status(''))
end)

test('finds binary paths in numstat', function()
  local out = z('1\t0\ttext.txt', '-\t-\timage.png')
  eq({ ['image.png'] = true }, git.parse_binary(out))
end)

test('skips the empty path field renames leave in numstat', function()
  -- A renamed entry is `add<TAB>del<TAB>` followed by the old and new paths.
  local out = z('0\t0\t', 'old.txt', 'new.txt', '-\t-\tblob.bin')
  eq({ ['blob.bin'] = true }, git.parse_binary(out))
end)

test('marks a binary rename by its new path', function()
  local out = z('-\t-\t', 'old.bin', 'new.bin')
  eq({ ['new.bin'] = true }, git.parse_binary(out))
end)

test('parses a cat-file batch stream', function()
  -- `<sha> <type> <size>` then exactly size bytes, then a newline.
  local out = table.concat({
    ('a'):rep(40) .. ' blob 7\nfoo\nbar\n',
    ('b'):rep(40) .. ' blob 4\nbaz\n\n',
  })
  eq({ { 'foo', 'bar' }, { 'baz' } }, git.parse_batch(out))
end)

test('reports missing objects in place', function()
  local out = table.concat({
    'HEAD:gone.txt missing\n',
    ('a'):rep(40) .. ' blob 4\nhey\n\n',
  })
  eq({ false, { 'hey' } }, git.parse_batch(out))
end)

test('a header line inside the content is not mistaken for a header', function()
  -- Content that looks like a batch header must be consumed by its size, not
  -- rescanned; only positional order links a result back to its request.
  local fake = ('c'):rep(40) .. ' blob 99'
  local body = fake .. '\ntail'
  local out = ('a'):rep(40) .. (' blob %d\n'):format(#body) .. body .. '\n'
  eq({ { fake, 'tail' } }, git.parse_batch(out))
end)

test('parses an empty batch', function()
  eq({}, git.parse_batch(''))
end)

test('keeps an empty blob distinct from a missing one', function()
  local out = ('a'):rep(40) .. ' blob 0\n\n'
  eq({ {} }, git.parse_batch(out))
end)

test('parses a NUL-separated path list', function()
  -- The stream is terminated rather than separated, so the trailing empty
  -- field is not a path.
  eq({ 'a.txt', 'dir/b b.txt' }, git.parse_paths(z('a.txt', 'dir/b b.txt')))
  eq({}, git.parse_paths(''))
end)

test('resolves the git directory of a repository and of a worktree', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'one' })
    repo.commit('init')
    eq(repo.root .. '/.git', git.dir(repo.root))

    -- A linked worktree has a `.git` file rather than a directory, and the
    -- directory it names is the one its index lives in.
    local tree = repo.root .. '/../unidiff-test-worktree'
    vim.fn.delete(tree, 'rf')
    repo.git('worktree', 'add', '-q', tree)
    eq(repo.root .. '/.git/worktrees/unidiff-test-worktree', git.dir(tree))
    vim.fn.delete(tree, 'rf')
  end)
end)

test('reports no git directory outside a repository', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  eq(nil, git.dir(dir))
  vim.fn.delete(dir, 'rf')
end)

test('tells a repository with a commit from one without', function()
  helpers.with_repo(function(repo)
    eq(false, git.has_head(repo.root))
    repo.write('a.txt', { 'one' })
    repo.commit('init')
    eq(true, git.has_head(repo.root))
  end)
end)

test('async runs git without blocking and hands over what it returned', function()
  helpers.with_repo(function(repo)
    local got
    git.async(function()
      return git.has_head(repo.root), git.dir(repo.root)
    end, function(...)
      got = { ... }
    end)
    -- Both commands are still running: nothing has had a chance to finish them.
    eq(nil, got)
    vim.wait(5000, function()
      return got ~= nil
    end)
    eq({ false, repo.root .. '/.git' }, got)
  end)
end)

test('async finishes at once when no command is run', function()
  local got
  git.async(function()
    return 1, nil, 3
  end, function(...)
    got = { n = select('#', ...), ... }
  end)
  eq({ n = 3, 1, nil, 3 }, got)
end)

test('run blocks as before outside async', function()
  helpers.with_repo(function(repo)
    eq(false, git.has_head(repo.root))
  end)
end)

--- `git log -z --format=...` separates commits with NUL and the fields within
--- one with a unit separator.
local function log_z(...)
  return table.concat({ ... }, '\0') .. '\0'
end

--- @param ... string
local function rec(...)
  return table.concat({ ... }, '\31')
end

test('parses a commit log', function()
  eq({
    {
      sha = 'abc1234',
      parents = { 'def5678' },
      subject = 'do a thing',
      author = 'Ada',
      when = '2 days ago',
    },
  }, git.parse_log(log_z(rec('abc1234', 'def5678', 'do a thing', 'Ada', '2 days ago'))))
end)

-- The root commit has no parent, and a merge has more than one. Which it is
-- decides what the commit can be compared against.
test('parses the parent list of a root commit and of a merge', function()
  local commits = git.parse_log(log_z(
    rec('m000000', 'p111111 p222222', 'merge', 'Ada', 'now'),
    rec('r000000', '', 'root', 'Ada', 'now')
  ))
  eq({ 'p111111', 'p222222' }, commits[1].parents)
  eq({}, commits[2].parents)
end)

-- A subject may hold anything but a newline, which is why the fields are
-- separated by a unit separator rather than by anything more plausible.
test('keeps a subject containing separators intact', function()
  local commits = git.parse_log(log_z(rec('abc1234', 'p', 'fix a | b, and "c"', 'Ada', 'now')))
  eq('fix a | b, and "c"', commits[1].subject)
end)

test('parses an empty log', function()
  eq({}, git.parse_log(''))
end)

test('lists the log of a real repository, newest first', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'one' })
    repo.commit('first')
    repo.write('a.txt', { 'two' })
    repo.commit('second')

    local commits = assert(git.log(10, repo.root))
    eq(2, #commits)
    eq('second', commits[1].subject)
    eq('first', commits[2].subject)
    eq({}, commits[2].parents)
    eq(commits[2].sha, commits[1].parents[1])
  end)
end)

-- A root commit has no parent to compare with, so it is the one case that
-- cannot go through `git diff`.
test('lists what a root commit added', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'one' })
    repo.write('b.txt', { 'two' })
    repo.commit('first')

    local commits = assert(git.log(1, repo.root))
    local changes = assert(git.changed_between(git.commit_range(commits[1]), repo.root))
    eq({ 'A', 'A' }, { changes[1].status, changes[2].status })
    eq({ 'a.txt', 'b.txt' }, { changes[1].path, changes[2].path })
  end)
end)

-- `git diff-tree -m` would emit one diff per parent with nothing to tell the
-- blocks apart, so the first parent is named explicitly instead.
test('compares a merge with its first parent only', function()
  helpers.with_repo(function(repo)
    repo.write('base.txt', { 'base' })
    repo.commit('first')
    repo.git('checkout', '-b', 'side')
    repo.write('side.txt', { 'side' })
    repo.commit('on side')
    repo.git('checkout', '-')
    repo.write('main.txt', { 'main' })
    repo.commit('on main')
    repo.git('merge', '--no-ff', 'side', '-m', 'merge side')

    local commits = assert(git.log(1, repo.root))
    eq(2, #commits[1].parents)
    local changes = assert(git.changed_between(git.commit_range(commits[1]), repo.root))
    -- Against the first parent only `side.txt` is new; `main.txt` would appear
    -- as well if the second parent were included.
    eq(1, #changes)
    eq('side.txt', changes[1].path)
  end)
end)

test('reads the whole message of a commit and its stat', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'one' })
    repo.commit('first')
    repo.write('a.txt', { 'two' })
    repo.write('b.txt', { 'new' })
    repo.git('add', '-A')
    repo.git('commit', '-qm', 'second\n\nwhy it changed\n\nand more\n')

    local commits = assert(git.log(1, repo.root))
    local detail = assert(git.commit_detail(commits[1], repo.root))
    eq('test <test@example.com>', detail.author)
    assert(detail.date ~= '', 'the date should be read')
    -- the trailing newline git keeps after the body is not a line of it
    eq({ 'second', '', 'why it changed', '', 'and more' }, detail.message)
    eq({
      ' a.txt | 2 +-',
      ' b.txt | 1 +',
      ' 2 files changed, 2 insertions(+), 1 deletion(-)',
    }, detail.stat)
  end)
end)

-- `color.ui = always` colors a stat even when it is not going to a terminal,
-- and a root commit has no parent to compare against.
test('reads the stat of a root commit without colors', function()
  helpers.with_repo(function(repo)
    repo.git('config', 'color.ui', 'always')
    repo.write('a.txt', { 'one' })
    repo.commit('first')

    local commits = assert(git.log(1, repo.root))
    local detail = assert(git.commit_detail(commits[1], repo.root))
    eq({ 'first' }, detail.message)
    eq({ ' a.txt | 1 +', ' 1 file changed, 1 insertion(+)' }, detail.stat)
  end)
end)

test('keeps the stat graph short', function()
  helpers.with_repo(function(repo)
    local lines = {}
    for i = 1, 100 do
      lines[i] = tostring(i)
    end
    repo.write('a.txt', lines)
    repo.commit('first')

    local commits = assert(git.log(1, repo.root))
    local detail = assert(git.commit_detail(commits[1], repo.root))
    eq(' a.txt | 100 ' .. ('+'):rep(30), detail.stat[1])
  end)
end)

-- The stat has to describe the same comparison as the diff under it.
test('reads the stat of a merge against its first parent', function()
  helpers.with_repo(function(repo)
    repo.write('base.txt', { 'base' })
    repo.commit('first')
    repo.git('checkout', '-b', 'side')
    repo.write('side.txt', { 'side' })
    repo.commit('on side')
    repo.git('checkout', '-')
    repo.write('main.txt', { 'main' })
    repo.commit('on main')
    repo.git('merge', '--no-ff', 'side', '-m', 'merge side')

    local commits = assert(git.log(1, repo.root))
    local detail = assert(git.commit_detail(commits[1], repo.root))
    eq({ ' side.txt | 1 +', ' 1 file changed, 1 insertion(+)' }, detail.stat)
  end)
end)

-- A range whose ends are two chosen commits is an ordinary comparison of two
-- trees, whatever either end is; only a single commit needs a parent chosen for
-- it.
test('lists what changed between two commits', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'one' })
    repo.commit('first')
    repo.write('b.txt', { 'two' })
    repo.commit('second')
    repo.write('c.txt', { 'three' })
    repo.commit('third')

    local commits = assert(git.log(3, repo.root))
    local changes = assert(git.changed_between({
      old = commits[3].sha,
      new = commits[1].sha,
    }, repo.root))
    eq({ 'b.txt', 'c.txt' }, vim.tbl_map(function(c)
      return c.path
    end, changes))
  end)
end)

--- A history that forks and merges: `side` and `main` are on branches that
--- diverged, so neither is an ancestor of the other.
--- @param repo gitview.TestRepo
--- @return table<string, string> sha by subject
local function forked(repo)
  repo.write('base.txt', { 'base' })
  repo.commit('first')
  repo.git('checkout', '-q', '-b', 'side')
  repo.write('side.txt', { 'side' })
  repo.commit('on side')
  repo.git('checkout', '-q', '-')
  repo.write('main.txt', { 'main' })
  repo.commit('on main')
  repo.git('merge', '-q', '--no-ff', 'side', '-m', 'merge side')

  local by_subject = {}
  for _, c in ipairs(assert(git.log(10, repo.root))) do
    by_subject[c.subject] = c.sha
  end
  return by_subject
end

test('tells a range along one line of history from one across a fork', function()
  helpers.with_repo(function(repo)
    local sha = forked(repo)
    eq(true, git.is_ancestor(sha['first'], sha['merge side'], repo.root))
    eq(true, git.is_ancestor(sha['on side'], sha['merge side'], repo.root))
    -- the two branch tips
    eq(false, git.is_ancestor(sha['on side'], sha['on main'], repo.root))
    eq(false, git.is_ancestor(sha['on main'], sha['on side'], repo.root))
  end)
end)

-- Across a fork the comparison also undoes whatever the other side did, which
-- is exactly why it is worth saying so rather than presenting it as a stretch
-- of history.
test('a range across a fork also undoes the other side', function()
  helpers.with_repo(function(repo)
    local sha = forked(repo)
    local changes = assert(git.changed_between({
      old = sha['on side'],
      new = sha['on main'],
    }, repo.root))
    local status = {}
    for _, c in ipairs(changes) do
      status[c.path] = c.status
    end
    eq({ ['main.txt'] = 'A', ['side.txt'] = 'D' }, status)
  end)
end)

-- A merge at either end is no special case: only a single commit has to have a
-- parent chosen for it.
test('a range ending at a merge needs no parent chosen', function()
  helpers.with_repo(function(repo)
    local sha = forked(repo)
    local changes = assert(git.changed_between({
      old = sha['first'],
      new = sha['merge side'],
    }, repo.root))
    eq({ 'main.txt', 'side.txt' }, vim.tbl_map(function(c)
      return c.path
    end, changes))
  end)
end)

-- A range with no new revision ends at the working tree, so it takes in what is
-- staged and what is not alike, and what git is not tracking as well.
test('a range can end at the working tree', function()
  helpers.with_repo(function(repo)
    repo.write('staged.txt', { 'one' })
    repo.write('unstaged.txt', { 'one' })
    repo.write('gone.txt', { 'one' })
    repo.commit('first')
    local sha = assert(git.log(1, repo.root))[1].sha
    repo.write('staged.txt', { 'two' })
    repo.git('add', 'staged.txt')
    repo.write('unstaged.txt', { 'two' })
    repo.git('rm', '-q', 'gone.txt')
    repo.write('loose.txt', { 'new' })

    local changes = assert(git.changed_between({ old = sha }, repo.root))
    local status = {}
    for _, c in ipairs(changes) do
      status[c.path] = c.status
    end
    eq({
      ['staged.txt'] = 'M',
      ['unstaged.txt'] = 'M',
      ['gone.txt'] = 'D',
      ['loose.txt'] = 'A',
    }, status)
  end)
end)

-- An untracked file is put in a copy of the index, so git sees it as it sees any
-- other file: the same path the old side had is a modification rather than a
-- deletion beside an addition, and a file moved without `git mv` is a rename.
test('an untracked file is compared as git compares a tracked one', function()
  helpers.with_repo(function(repo)
    repo.write('back.txt', { 'one' })
    repo.write('moved.txt', { 'a', 'b', 'c', 'd' })
    repo.commit('first')
    local sha = assert(git.log(1, repo.root))[1].sha
    repo.git('rm', '-q', 'back.txt')
    repo.commit('second')
    repo.write('back.txt', { 'two' })
    repo.git('mv', 'moved.txt', 'kept.txt')
    repo.git('rm', '-q', '--cached', 'kept.txt')

    local before = repo.git('status', '--porcelain')
    local changes = assert(git.changed_between({ old = sha }, repo.root))
    local status = {}
    for _, c in ipairs(changes) do
      status[c.old_path .. ' -> ' .. c.path] = c.status
    end
    eq({ ['back.txt -> back.txt'] = 'M', ['moved.txt -> kept.txt'] = 'R' }, status)
    -- the real index is left as it was
    eq(before, repo.git('status', '--porcelain'))
  end)
end)

-- The session has listed the untracked files already, and hands them over
-- rather than have the working tree walked again.
test('a range to the working tree takes the untracked files it is given', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'one' })
    repo.commit('first')
    local sha = assert(git.log(1, repo.root))[1].sha
    repo.write('listed.txt', { 'new' })
    repo.write('unlisted.txt', { 'new' })

    local changes = assert(git.changed_between({ old = sha }, repo.root, { 'listed.txt' }))
    eq({ 'listed.txt' }, vim.tbl_map(function(c)
      return c.path
    end, changes))
  end)
end)
