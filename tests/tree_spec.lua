local tree = require('gitview.tree')

local test, eq = _G.test, _G.eq

--- One line per row: indent, then the directory with a slash or the file's
--- index, then the column its name starts at.
--- @param nodes gitview.TreeNode[]
--- @return string[]
local function dump(nodes)
  return vim.tbl_map(function(n)
    local what = n.dir and (n.dir == '' and './' or n.dir .. '/') or ('#%d'):format(n.index)
    return ('%s%s @%d'):format(('  '):rep(n.depth), what, n.col)
  end, nodes)
end

test('tree: no paths leave the root alone', function()
  eq({ './ @0' }, dump(tree.build({})))
end)

-- The root's children are not indented below it, so no row loses a level to it.
test('tree: files at the top sit beside the root', function()
  eq({ './ @0', '#1 @0', '#2 @0' }, dump(tree.build({ 'a.txt', 'b.txt' })))
end)

test('tree: a directory comes before its files, which sit a level in', function()
  eq({
    './ @0',
    '#1 @0',
    'docs/ @0',
    '  #2 @5',
    '  #3 @5',
  }, dump(tree.build({ 'README.md', 'docs/a.md', 'docs/b.md' })))
end)

-- A directory with one file is still a directory row and a file row, the same
-- as any other.
test('tree: a directory of one file keeps its own row', function()
  eq({ './ @0', 'tests/ @0', '  #1 @6' }, dump(tree.build({ 'tests/a_spec.lua' })))
end)

test('tree: a directory holding only a directory is one row with it', function()
  eq({
    './ @0',
    'lua/gitview/ @0',
    '  #1 @12',
    '  lua/gitview/ui/ @12',
    '    #2 @15',
  }, dump(tree.build({ 'lua/gitview/init.lua', 'lua/gitview/ui/list.lua' })))
end)

-- Even with a single directory below it, the root is a row of its own: it is
-- always the first row, whatever the paths are.
test('tree: the root is never taken together with a directory', function()
  eq({ './ @0', 'a/b/ @0', '  #1 @4' }, dump(tree.build({ 'a/b/x' })))
end)

-- In byte order `.` and `-` sort before `/`, so a directory comes after a sibling
-- whose name it begins. The files keep the order they were given in.
test('tree: files keep their order where a name begins a directory name', function()
  eq({
    './ @0',
    'a-b/ @0',
    '  #1 @4',
    '#2 @0',
    'a/ @0',
    '  #3 @2',
  }, dump(tree.build({ 'a-b/y', 'a.lua', 'a/x' })))
  eq({
    './ @0',
    'src/ @0',
    '  #1 @4',
    '  #2 @4',
    '  src/util/ @4',
    '    #3 @9',
  }, dump(tree.build({ 'src/ui.lua', 'src/util.lua', 'src/util/path.lua' })))
end)

-- A deleted file and a new directory can share a name in one listing.
test('tree: a file and a directory of the same name are both rows', function()
  eq({ './ @0', '#1 @0', 'a/ @0', '  #2 @2' }, dump(tree.build({ 'a', 'a/x' })))
end)
