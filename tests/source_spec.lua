local git = require('gitview.git')
local source = require('gitview.diff.source')
local helpers = dofile('tests/helpers.lua')

local test, eq = _G.test, _G.eq

-- The working tree has no revision to read a blob from, so a range ending there
-- reads the new side from the file itself.
test('a range ending at the working tree reads the new side from the file', function()
  helpers.with_repo(function(repo)
    repo.write('a.txt', { 'one' })
    repo.write('b.txt', { 'one' })
    repo.commit('first')
    local sha = assert(git.log(1, repo.root))[1].sha
    repo.write('a.txt', { 'two' })
    repo.git('add', 'a.txt')
    repo.write('a.txt', { 'three' })
    vim.fn.delete(repo.root .. '/b.txt')

    local sources = assert(source.for_range({ old = sha }, repo.root))
    local by_label = {}
    for _, src in ipairs(sources) do
      by_label[src.label] = src
    end
    -- the index's `two` is skipped over: the new side is the working tree
    eq({ 'one' }, by_label['a.txt'].old_lines)
    eq({ 'three' }, by_label['a.txt'].new_lines)
    eq({ 'one' }, by_label['b.txt'].old_lines)
    eq({}, by_label['b.txt'].new_lines)
  end)
end)
