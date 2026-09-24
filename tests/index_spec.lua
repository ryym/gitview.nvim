local index = require('unidiff.index')
local mixed = require('unidiff.diff.mixed')
local source = require('unidiff.diff.source')
local status = require('unidiff.status')
local helpers = dofile('tests/helpers.lua')

local test, eq = _G.test, _G.eq

--- @param fields table
--- @return unidiff.Line
local function row(fields)
  return vim.tbl_extend('force', { text = '', kind = 'add', side = 'new' }, fields)
end

test('apply: an insertion goes in front of its index position', function()
  eq(
    { 'a', 'x', 'b' },
    index.apply({ 'a', 'b' }, { row({ text = 'x', index_pos = 2 }) })
  )
end)

test('apply: a row read from the index drops that line', function()
  eq(
    { 'a', 'c' },
    index.apply({ 'a', 'b', 'c' }, { row({ kind = 'del', side = 'index', index_pos = 2 }) })
  )
end)

test('apply: an insertion one past the end is an append', function()
  eq({ 'a', 'x' }, index.apply({ 'a' }, { row({ text = 'x', index_pos = 2 }) }))
end)

test('apply: a replaced line drops and inserts at the same position', function()
  eq({ 'a', 'B', 'c' }, index.apply({ 'a', 'b', 'c' }, {
    row({ kind = 'del', side = 'index', index_pos = 2 }),
    row({ text = 'B', index_pos = 2 }),
  }))
end)

test('apply: several insertions at one position keep the order given', function()
  eq({ 'x', 'y', 'z', 'a' }, index.apply({ 'a' }, {
    row({ text = 'x', index_pos = 1 }),
    row({ text = 'y', index_pos = 1 }),
    row({ text = 'z', index_pos = 1 }),
  }))
end)

-- Positions are read off the rows, so rows further down cannot be shifted by
-- what rows above them did.
test('apply: rows at many positions do not shift each other', function()
  eq({ 'X', 'b', 'c', 'Y' }, index.apply({ 'a', 'b', 'c', 'd' }, {
    row({ kind = 'del', side = 'index', index_pos = 1 }),
    row({ text = 'X', index_pos = 1 }),
    row({ kind = 'del', side = 'index', index_pos = 4 }),
    row({ text = 'Y', index_pos = 4 }),
  }))
end)

test('apply: no rows leaves the index as it stands', function()
  eq({ 'a', 'b' }, index.apply({ 'a', 'b' }, {}))
end)

local layers = {
  row({ stage = 'unstaged', index_pos = 1 }),
  row({ stage = 'staged', index_pos = 1 }),
  row({ stage = 'index', kind = 'del', side = 'index', index_pos = 1 }),
  row({ kind = 'context', side = 'index', index_pos = 1 }),
  row({ kind = 'gap' }),
}

test('selection: staging takes the unstaged layer and the index-only rows', function()
  eq({ layers[1], layers[3] }, index.selection(layers, 1, #layers, 'stage'))
end)

test('selection: unstaging takes the staged layer and the index-only rows', function()
  eq({ layers[2], layers[3] }, index.selection(layers, 1, #layers, 'unstage'))
end)

test('selection: a range outside the rows is clamped rather than an error', function()
  eq({ layers[1], layers[3] }, index.selection(layers, -5, 99, 'stage'))
  eq({}, index.selection(layers, 4, 5, 'stage'))
end)

test('hunk_at: a run of changed rows is found from anywhere inside it', function()
  local lines = {
    row({ kind = 'context' }),
    row({ kind = 'del' }),
    row({ kind = 'add' }),
    row({ kind = 'add' }),
    row({ kind = 'context' }),
  }
  for r = 2, 4 do
    local first, last = index.hunk_at(lines, r)
    eq({ 2, 4 }, { first, last })
  end
end)

test('hunk_at: a gap ends a run, and a context row is in none', function()
  local lines = {
    row({ kind = 'add' }),
    row({ kind = 'gap' }),
    row({ kind = 'add' }),
  }
  eq({ 1, 1 }, { index.hunk_at(lines, 1) })
  eq(nil, index.hunk_at(lines, 2))
  eq({ 3, 3 }, { index.hunk_at(lines, 3) })
end)

--- The mixed view's rows for one file of a real repository, untrimmed so that
--- every row is addressable by position.
--- @param repo unidiff.TestRepo
--- @param path string
--- @return unidiff.Line[] rows
--- @return unidiff.StatusEntry entry
--- @return unidiff.Source src
local function view_rows(repo, path)
  local entry
  for _, e in ipairs(assert(status.list(repo.root))) do
    if e.path == path then
      entry = e
    end
  end
  assert(entry, 'no entry for ' .. path)
  local src = assert(source.for_entry(entry, repo.root))
  return mixed.merge(src.old_lines, src.index_lines, src.new_lines), entry, src
end

--- Apply one operation to every row of the view that it moves, then write it.
--- @param repo unidiff.TestRepo
--- @param path string
--- @param op 'stage'|'unstage'
local function apply_all(repo, path, op)
  local rows, entry, src = view_rows(repo, path)
  local picked = index.selection(rows, 1, #rows, op)
  return index.write(op, entry, index.apply(src.index_lines, picked), repo.root)
end

test('staging every unstaged row leaves nothing unstaged', function()
  helpers.with_repo(function(repo)
    repo.write('f.txt', { 'a', 'b', 'c', 'd' })
    repo.commit('init')
    repo.write('f.txt', { 'a', 'B', 'c', 'd', 'e' })
    repo.git('add', 'f.txt')
    repo.write('f.txt', { 'A', 'B', 'd', 'e', 'f' })

    eq(nil, apply_all(repo, 'f.txt', 'stage'))
    -- The index now equals the working tree, whatever was staged before.
    eq('', repo.git('diff'))
    eq('M  f.txt\n', repo.git('status', '--short'))
  end)
end)

test('unstaging every staged row leaves nothing staged', function()
  helpers.with_repo(function(repo)
    repo.write('f.txt', { 'a', 'b', 'c', 'd' })
    repo.commit('init')
    repo.write('f.txt', { 'a', 'B', 'c', 'd', 'e' })
    repo.git('add', 'f.txt')
    repo.write('f.txt', { 'A', 'B', 'd', 'e', 'f' })

    eq(nil, apply_all(repo, 'f.txt', 'unstage'))
    eq('', repo.git('diff', '--cached'))
    eq(' M f.txt\n', repo.git('status', '--short'))
  end)
end)

-- Staging one row at a time is the case the index positions have to survive:
-- each write moves every position below it.
test('staging one row at a time converges on a clean working tree', function()
  helpers.with_repo(function(repo)
    repo.write('f.txt', { 'one', 'two', 'three', 'four', 'five' })
    repo.commit('init')
    repo.write('f.txt', { 'ONE', 'two', 'four', 'inserted', 'five', 'last' })

    for _ = 1, 20 do
      local rows, entry, src = view_rows(repo, 'f.txt')
      local picked = index.selection(rows, 1, #rows, 'stage')
      if #picked == 0 then
        break
      end
      eq(nil, index.write('stage', entry, index.apply(src.index_lines, { picked[1] }), repo.root))
    end

    eq('', repo.git('diff'))
    eq({ 'ONE', 'two', 'four', 'inserted', 'five', 'last' }, vim.fn.readfile(repo.root .. '/f.txt'))
  end)
end)

test('staging part of an untracked file creates the index entry', function()
  helpers.with_repo(function(repo)
    repo.write('kept.txt', { 'x' })
    repo.commit('init')
    repo.write('new.txt', { 'one', 'two' })

    local rows, entry, src = view_rows(repo, 'new.txt')
    local picked = index.selection(rows, 1, 1, 'stage')
    eq(1, #picked)
    eq(nil, index.write('stage', entry, index.apply(src.index_lines, picked), repo.root))
    eq('AM new.txt\n', repo.git('status', '--short'))
    eq('one\n', repo.git('show', ':new.txt'))
  end)
end)

-- Unstaging all of a file HEAD does not have has to leave no entry at all. An
-- empty blob would report a staged empty file plus unstaged additions.
test('unstaging all of an added file takes it out of the index', function()
  helpers.with_repo(function(repo)
    repo.write('kept.txt', { 'x' })
    repo.commit('init')
    repo.write('new.txt', { 'one', 'two' })
    repo.git('add', 'new.txt')

    eq(nil, apply_all(repo, 'new.txt', 'unstage'))
    eq('?? new.txt\n', repo.git('status', '--short'))
    eq({ 'one', 'two' }, vim.fn.readfile(repo.root .. '/new.txt'))
  end)
end)

test('staging the deletion of every line removes the index entry', function()
  helpers.with_repo(function(repo)
    repo.write('gone.txt', { 'one', 'two' })
    repo.commit('init')
    vim.fn.delete(repo.root .. '/gone.txt')

    eq(nil, apply_all(repo, 'gone.txt', 'stage'))
    eq('D  gone.txt\n', repo.git('status', '--short'))
  end)
end)

test('an executable file keeps its mode', function()
  helpers.with_repo(function(repo)
    repo.write('run.sh', { 'echo one' })
    vim.fn.setfperm(repo.root .. '/run.sh', 'rwxr-xr-x')
    repo.commit('init')
    repo.write('run.sh', { 'echo one', 'echo two' })

    eq(nil, apply_all(repo, 'run.sh', 'stage'))
    assert(repo.git('ls-files', '-s', '--', 'run.sh'):match('^100755 '), 'mode lost')
  end)
end)

-- An untracked executable has no index entry to carry a mode over from, so the
-- working tree is the only thing that can say what it is.
test('an untracked executable is staged as executable', function()
  helpers.with_repo(function(repo)
    repo.write('kept.txt', { 'x' })
    repo.commit('init')
    repo.write('run.sh', { 'echo one' })
    vim.fn.setfperm(repo.root .. '/run.sh', 'rwxr-xr-x')

    eq(nil, apply_all(repo, 'run.sh', 'stage'))
    assert(repo.git('ls-files', '-s', '--', 'run.sh'):match('^100755 '), 'mode lost')
  end)
end)
