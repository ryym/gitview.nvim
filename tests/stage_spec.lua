local stage = require('unidiff.stage')
local status = require('unidiff.status')
local helpers = dofile('tests/helpers.lua')

local test, eq = _G.test, _G.eq

--- @param fields table
--- @return unidiff.StatusEntry
local function entry(fields)
  return vim.tbl_extend('force', {
    path = 'a.txt',
    head_path = 'a.txt',
    index_status = ' ',
    worktree_status = ' ',
    binary = false,
  }, fields)
end

--- The entry for one path, as the session would have it.
--- @param repo unidiff.TestRepo
--- @param path string
--- @return unidiff.StatusEntry
local function entry_for(repo, path)
  local entries = assert(status.list(repo.root))
  for _, e in ipairs(entries) do
    if e.path == path then
      return e
    end
  end
  error('no entry for ' .. path)
end

test('stage: one command covers every kind of change', function()
  -- `git add` stages a deletion as well as content, so nothing branches on the
  -- status letter.
  for _, letter in ipairs({ 'M', 'D', '?' }) do
    eq(
      { what = 'git add', args = { 'add', '--', 'a.txt' } },
      (stage.stage(entry({ worktree_status = letter })))
    )
  end
end)

test('stage: an entry with nothing unstaged says so instead', function()
  local action, why = stage.stage(entry({ index_status = 'M' }))
  eq(nil, action)
  eq('nothing to stage in a.txt', why)
end)

test('unstage: restores the index from HEAD', function()
  eq(
    { what = 'git restore --staged', args = { 'restore', '--staged', '--', 'a.txt' } },
    (stage.unstage(entry({ index_status = 'M' }), true))
  )
end)

test('unstage: a staged rename passes both of its names', function()
  -- Restoring only the new path would leave the old one deleted in the index.
  eq(
    { what = 'git restore --staged', args = { 'restore', '--staged', '--', 'new.txt', 'old.txt' } },
    (stage.unstage(entry({ path = 'new.txt', head_path = 'old.txt', index_status = 'R' }), true))
  )
end)

test('unstage: without a HEAD the entry leaves the index instead', function()
  eq(
    { what = 'git rm --cached', args = { 'rm', '--cached', '-f', '-q', '--', 'a.txt' } },
    (stage.unstage(entry({ index_status = 'A', head_path = nil }), false))
  )
end)

test('unstage: an untracked file has nothing staged', function()
  -- Both its letters are `?`, which is not the unchanged letter, so the test
  -- has to be more than "the index letter differs".
  local action, why = stage.unstage(entry({ index_status = '?', worktree_status = '?' }), true)
  eq(nil, action)
  eq('nothing to unstage in a.txt', why)
end)

test('stages a modification in a real repository', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'one' })
    repo.commit('init')
    repo.write('a.txt', { 'two' })

    eq(nil, stage.run(assert(stage.stage(entry_for(repo, 'a.txt'))), repo.root))
    eq('M  a.txt\n', repo.git('status', '--short'))
  end)
end)

test('unstaging a rename leaves no half-staged index', function()
  helpers.with_repo(function(repo)
    repo.write('old.txt', { 'a', 'b', 'c' })
    repo.commit('init')
    repo.git('mv', 'old.txt', 'new.txt')

    eq(nil, stage.run(assert(stage.unstage(entry_for(repo, 'new.txt'), true)), repo.root))
    -- The index matches HEAD again: the rename is now entirely unstaged.
    eq('', repo.git('diff', '--cached'))
  end)
end)

test('unstaging before the first commit takes the file out of the index', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'one' })
    repo.git('add', '-A')
    -- Editing it again is what makes `git rm --cached` refuse without `-f`:
    -- the index entry then matches neither the file nor HEAD.
    repo.write('a.txt', { 'one', 'two' })

    local e = entry_for(repo, 'a.txt')
    eq(nil, stage.run(assert(stage.unstage(e, false)), repo.root))
    eq('?? a.txt\n', repo.git('status', '--short'))
    eq({ 'one', 'two' }, vim.fn.readfile(repo.root .. '/a.txt'))
  end)
end)

-- `git restore --staged` on an unmerged path succeeds and leaves an ordinary
-- modification: the merge stages are gone and the conflict is neither resolved
-- nor recorded. Staging one is a real workflow, so only unstaging is refused.
test('unstage: an unmerged path is refused', function()
  local action, why = stage.unstage(entry({ index_status = 'U', conflicted = true }), true)
  eq(nil, action)
  assert(why and why:find('unresolved conflict', 1, true), tostring(why))
end)

test('stage: an unmerged path is allowed, and resolves it', function()
  eq(
    { what = 'git add', args = { 'add', '--', 'a.txt' } },
    (stage.stage(entry({ index_status = 'U', worktree_status = 'U', conflicted = true })))
  )
end)
