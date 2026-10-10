--- The file list laid out as a tree: which rows stand for directories, and how
--- deep each row sits.
---
--- Only the shape is decided here. Each file keeps its place in the input, so the
--- rows from top to bottom are the files in the order they were given, with the
--- directories that hold them in between. That order is what `]f`, the files of
--- a multi-file diff and `git diff` itself go by, and keeping it is why siblings
--- are not sorted here: a directory is not put before its sibling files.
---
--- The input has to be in byte order, which is how git lists paths and how the
--- status entries are sorted. In byte order a directory's paths are contiguous,
--- and the order siblings first appear in is the order git sorts a tree in,
--- where a directory `a` compares as `a/`: `a.lua` comes before `a/x`. This
--- relies on Lua comparing strings bytewise, which LuaJIT does; a Neovim built
--- on PUC Lua compares by locale instead.
local M = {}

--- @class gitview.TreeNode one row of the tree
--- @field depth integer how far the row is indented, in levels
--- @field dir string? the directory the row stands for, without a trailing
---        slash; `''` for the root
--- @field index integer? the file the row stands for, as an index into the input
--- @field col integer 0-based byte column of the path where the row's own name
---        begins; what comes before it is the parent directory's path

--- @class gitview.TreeDir
--- @field path string
--- @field children (gitview.TreeDir|integer)[] subdirectories, and files by
---        index, in the order they first appear
--- @field dirs table<string, gitview.TreeDir> the subdirectories by name

--- @param path string
--- @return gitview.TreeDir
local function new_dir(path)
  return { path = path, children = {}, dirs = {} }
end

--- @param path string
--- @return string
local function prefix_of(path)
  return path == '' and '' or path .. '/'
end

--- A directory holding nothing but one other directory, taken together with
--- it, so that `lua/` and `gitview/` become the one row `lua/gitview/`. A narrow
--- sidebar would otherwise spend a level of indent on each.
--- @param d gitview.TreeDir
--- @return gitview.TreeDir
local function compact(d)
  while #d.children == 1 and type(d.children[1]) == 'table' do
    d = d.children[1] --[[@as gitview.TreeDir]]
  end
  return d
end

--- Lay out paths as a tree, with a row for the root at the top.
---
--- The root's children sit at the root's own depth rather than below it: every
--- row would otherwise lose a level of indent to a row that is always there.
---
--- @param paths string[] in byte order; see the module comment
--- @return gitview.TreeNode[]
function M.build(paths)
  local root = new_dir('')
  for i, path in ipairs(paths) do
    local d = root
    local parts = vim.split(path, '/', { plain = true })
    for k = 1, #parts - 1 do
      local name = parts[k]
      local sub = d.dirs[name]
      if not sub then
        sub = new_dir(prefix_of(d.path) .. name)
        d.dirs[name] = sub
        d.children[#d.children + 1] = sub
      end
      d = sub
    end
    d.children[#d.children + 1] = i
  end

  local nodes = { { depth = 0, dir = '', col = 0 } } --- @type gitview.TreeNode[]
  --- @param d gitview.TreeDir
  --- @param depth integer
  local function walk(d, depth)
    local col = #prefix_of(d.path)
    for _, child in ipairs(d.children) do
      if type(child) == 'number' then
        nodes[#nodes + 1] = { depth = depth, index = child, col = col }
      else
        local sub = compact(child)
        nodes[#nodes + 1] = { depth = depth, dir = sub.path, col = col }
        walk(sub, depth + 1)
      end
    end
  end
  walk(root, 0)
  return nodes
end

return M
