local status = require('unidiff.status')
local helpers = dofile('tests/helpers.lua')

local test, eq = _G.test, _G.eq

--- @param s string letter
--- @param path string
--- @param old_path string?
--- @return unidiff.Change
local function change(s, path, old_path)
  return { status = s, path = path, old_path = old_path or path, binary = false }
end

--- `<X><Y> <path>`, plus ` <- <head path>` when HEAD names the file differently
--- @param entries unidiff.StatusEntry[]
--- @return string[]
local function dump(entries)
  local out = {}
  for i, e in ipairs(entries) do
    out[i] = ('%s%s %s'):format(e.index_status, e.worktree_status, e.path)
    if e.head_path ~= e.path then
      out[i] = out[i] .. ' <- ' .. tostring(e.head_path)
    end
  end
  return out
end

test('status: one entry per file, whichever side changed', function()
  local entries = status.entries(
    { change('M', 'staged.txt') },
    { change('M', 'work.txt') },
    { 'new.txt' }
  )
  eq({ '?? new.txt <- nil', 'M  staged.txt', ' M work.txt' }, dump(entries))
end)

-- The point of the single list: a file changed on both sides is still one row.
test('status: a file changed on both sides gets one entry', function()
  local entries = status.entries({ change('M', 'a.txt') }, { change('M', 'a.txt') }, {})
  eq({ 'MM a.txt' }, dump(entries))
end)

-- `git diff` names paths as the index has them, so the rename's new name is
-- what the two listings have in common.
test('status: a staged rename edited again joins on the index path', function()
  local entries =
    status.entries({ change('R', 'new.txt', 'old.txt') }, { change('M', 'new.txt') }, {})
  eq({ 'RM new.txt <- old.txt' }, dump(entries))
  eq(true, entries[1].in_index)
end)

test('status: a staged addition has no version in HEAD', function()
  local entries = status.entries({ change('A', 'a.txt') }, {}, {})
  eq(nil, entries[1].head_path)
  eq(true, entries[1].in_index)
end)

test('status: a staged deletion leaves nothing in the index', function()
  local entries = status.entries({ change('D', 'a.txt') }, {}, {})
  eq('a.txt', entries[1].head_path)
  eq(false, entries[1].in_index)
end)

test('status: a binary flag on either side marks the entry', function()
  local c = change('M', 'a.bin')
  c.binary = true
  eq(true, status.entries({}, { c }, {})[1].binary)
  eq(true, status.entries({ c }, {}, {})[1].binary)
end)

test('status: labels name both sides of a rename only', function()
  eq('old.txt -> new.txt', status.label({ path = 'new.txt', head_path = 'old.txt' }))
  eq('a.txt', status.label({ path = 'a.txt', head_path = 'a.txt' }))
  eq('a.txt', status.label({ path = 'a.txt' }))
end)

test('status: a NUL byte near the start means binary', function()
  helpers.with_repo(function(repo)
    repo.write('text.txt', { 'plain', 'lines' })
    local f = assert(io.open(repo.root .. '/blob.bin', 'wb'))
    f:write('PNG\0\1\2\3')
    f:close()
    eq(false, status.looks_binary(repo.root .. '/text.txt'))
    eq(true, status.looks_binary(repo.root .. '/blob.bin'))
    eq(false, status.looks_binary(repo.root .. '/missing.txt'))
  end)
end)

-- Everything above builds entries from listings that were written by hand.
-- This is the check that the listings themselves are asked for correctly.
test('status: lists a real repository', function()
  helpers.with_repo(function(repo)
    repo.write('kept.txt', { 'same' })
    repo.write('edit.txt', { 'one' })
    repo.write('gone.txt', { 'bye' })
    repo.write('move.txt', { 'a', 'b', 'c', 'd' })
    repo.commit('init')

    repo.write('edit.txt', { 'two' }) -- staged, then edited again
    repo.git('add', 'edit.txt')
    repo.write('edit.txt', { 'three' })
    repo.git('rm', '-q', 'gone.txt') -- staged deletion
    repo.git('mv', 'move.txt', 'moved.txt') -- staged rename
    repo.write('added.txt', { 'new' }) -- staged addition
    repo.git('add', 'added.txt')
    repo.write('loose.txt', { 'untracked' })
    repo.write('ignored.log', { 'noise' })
    repo.write('.gitignore', { '*.log' })
    repo.git('add', '.gitignore')

    local entries, err = status.list(repo.root)
    assert(entries, err and err.what)
    eq({
      'A  .gitignore <- nil',
      'A  added.txt <- nil',
      'MM edit.txt',
      'D  gone.txt',
      '?? loose.txt <- nil',
      'R  moved.txt <- move.txt',
    }, dump(entries))
  end)
end)

test('status: an unchanged repository lists nothing', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'x' })
    repo.commit('init')
    eq({}, status.list(repo.root))
  end)
end)

test('status: reports a directory that is not a repository', function()
  helpers.with_non_repo(function(dir)
    local entries, err = status.list(dir)
    eq(nil, entries)
    assert(err, 'no error returned')
    eq('git diff --cached', err.what)
    assert(err.stderr ~= '', 'the failure should carry stderr')
  end)
end)
