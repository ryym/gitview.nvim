--- What `make bench` measures: a repository to build, and what to do in it.
---
--- Each scenario's `setup` runs once, in the driver, against a fresh repository.
--- Its `measure` runs in every sample, in a Neovim of its own with a session
--- already open on that repository, and returns the numbers to record. Both
--- touch the plugin only as a user would: through git and through keys.
local M = {}

--- @class gitview.BenchScenario
--- @field name string
--- @field about string what it stands for, for the report
--- @field setup fun(repo: gitview.TestRepo)
--- @field measure fun(ctx: gitview.BenchContext): table<string, number>
--- @field lang string? the language highlighted, whose path is reported
--- @field path ('treesitter'|'syntax')? the highlighting path `lang` is meant
---        to take; a sample that finds the other is reported
--- @field requires string? a parser the scenario needs, skipped without it

--- Lines of Lua that vary from row to row, so that a diff of them pairs and
--- highlights as real code does.
--- @param n integer
--- @param seed integer
--- @return string[]
local function lua_lines(n, seed)
  local t = {}
  for i = 1, n do
    local k = (i * 7 + seed) % 5
    if k == 0 then
      t[i] = ('local v%d = require("mod%d")'):format(i, i % 13)
    elseif k == 1 then
      t[i] = ('function M.f%d(a, b) return a + b * %d end'):format(i, i)
    elseif k == 2 then
      t[i] = ('  -- comment %d about things'):format(i)
    elseif k == 3 then
      t[i] = ('  if x%d then print("s%d", %d) end'):format(i, i, i)
    else
      t[i] = ''
    end
  end
  return t
end

--- @param n integer
--- @param seed integer
--- @return string[]
local function scss_lines(n, seed)
  local t = {}
  for i = 1, n do
    local k = (i + seed) % 4
    if k == 0 then
      t[i] = ('.block-%d { color: $c%d; margin: %dpx 0; }'):format(i, i % 7, i % 20)
    elseif k == 1 then
      t[i] = ('  &:hover { background: darken($bg, %d%%); }'):format(i % 30)
    elseif k == 2 then
      t[i] = ('$var-%d: %dpx; // spacing'):format(i, i)
    else
      t[i] = ('@include mixin-%d($a, $b);'):format(i % 11)
    end
  end
  return t
end

--- `lines` with every `every`th line changed.
--- @param lines string[]
--- @param every integer
--- @return string[]
local function edit_every(lines, every)
  local t = vim.deepcopy(lines)
  for i = every, #t, every do
    t[i] = t[i] .. ' -- edited'
  end
  return t
end

--- One line of `n` statements, as a bundler writes them.
--- @param n integer
--- @return string
local function minified(n)
  local t = {}
  for i = 1, n do
    t[i] = ('a.b(%d);'):format(i)
  end
  return table.concat(t)
end

--- A file that sorts before every other, changed, so that the row the cursor
--- starts on draws something small: what is measured is moving onto a target.
--- @param repo gitview.TestRepo
local function with_starter(repo)
  repo.write('0.txt', { 'before' })
end

--- @param repo gitview.TestRepo
local function change_starter(repo)
  repo.write('0.txt', { 'after' })
end

--- A commit to look at, with a small one after it, so that entering the commits
--- pane lands on the small one rather than on the target.
--- @param repo gitview.TestRepo
--- @param subject string
--- @param write fun()
local function target_commit(repo, subject, write)
  repo.write('base.txt', { 'base' })
  repo.commit('base')
  write()
  repo.commit(subject)
  repo.write('base.txt', { 'after' })
  repo.commit('small')
end

--- An uncommitted change to one file.
--- @param path string
--- @param old string[]
--- @param new string[]
--- @return fun(repo: gitview.TestRepo)
local function worktree_change(path, old, new)
  return function(repo)
    with_starter(repo)
    repo.write(path, old)
    repo.commit('init')
    change_starter(repo)
    repo.write(path, new)
  end
end

--- Select a file of the uncommitted changes.
--- @param path string
--- @return fun(ctx: gitview.BenchContext): table<string, number>
local function select_file(path)
  return function(ctx)
    ctx.focus('files')
    local t = ctx.select(path)
    return { shown_ms = t.shown, full_ms = t.full }
  end
end

--- Select a commit in the commits pane.
--- @param subject string
--- @return fun(ctx: gitview.BenchContext): table<string, number>
local function select_commit(subject)
  return function(ctx)
    ctx.focus('commits')
    local t = ctx.select(subject)
    return { shown_ms = t.shown, full_ms = t.full }
  end
end

--- @param files integer
--- @return fun(repo: gitview.TestRepo)
local function many_files(files)
  return function(repo)
    target_commit(repo, 'target', function()
      for f = 1, files do
        repo.write(('f%02d.lua'):format(f), lua_lines(360, f))
      end
      repo.commit('init')
      for f = 1, files do
        repo.write(('f%02d.lua'):format(f), edit_every(lua_lines(360, f), 15))
      end
    end)
  end
end

--- @param n integer
--- @return fun(repo: gitview.TestRepo)
local function rewrite(n)
  local old = lua_lines(n, 1)
  return worktree_change('rewrite.lua', old, edit_every(old, 1))
end

local huge = lua_lines(50000, 1)
local huge_edited = vim.deepcopy(huge)
huge_edited[25000] = huge_edited[25000] .. ' -- edited'

--- @type gitview.BenchScenario[]
M.list = {
  {
    name = 'commit_many_files',
    about = 'a commit of 60 files of 360 lines, every 15th line changed',
    lang = 'lua',
    path = 'treesitter',
    setup = many_files(60),
    measure = select_commit('target'),
  },
  {
    name = 'commit_many_files_s',
    about = 'commit_many_files with a quarter of the files',
    lang = 'lua',
    path = 'treesitter',
    setup = many_files(15),
    measure = select_commit('target'),
  },
  {
    name = 'file_huge',
    about = 'one line changed in a file of 50,000 lines',
    lang = 'lua',
    path = 'treesitter',
    setup = worktree_change('huge.lua', huge, huge_edited),
    measure = select_file('huge.lua'),
  },
  {
    name = 'file_rewrite',
    about = 'every line of a 5000-line file changed; then moving in the diff',
    lang = 'lua',
    path = 'treesitter',
    setup = rewrite(5000),
    measure = function(ctx)
      ctx.focus('files')
      local t = ctx.select('rewrite.lua')
      ctx.focus('diff')
      local move = 0
      for _ = 1, 50 do
        move = move + ctx.keys('j').full
      end
      local page = 0
      for _ = 1, 20 do
        page = page + ctx.keys('<C-f>').full
      end
      return { shown_ms = t.shown, full_ms = t.full, move_ms = move / 50, page_ms = page / 20 }
    end,
  },
  {
    name = 'file_rewrite_s',
    about = 'file_rewrite with a quarter of the lines',
    lang = 'lua',
    path = 'treesitter',
    setup = rewrite(1250),
    measure = select_file('rewrite.lua'),
  },
  {
    name = 'file_hunks',
    about = 'every 4th line changed in a 4000-line file',
    lang = 'lua',
    path = 'treesitter',
    setup = function(repo)
      local old = lua_lines(4000, 2)
      worktree_change('hunks.lua', old, edit_every(old, 4))(repo)
    end,
    measure = select_file('hunks.lua'),
  },
  {
    name = 'file_added',
    about = 'a new file of 5000 lines',
    lang = 'lua',
    path = 'treesitter',
    setup = function(repo)
      with_starter(repo)
      repo.commit('init')
      change_starter(repo)
      repo.write('added.lua', lua_lines(5000, 3))
    end,
    measure = select_file('added.lua'),
  },
  {
    name = 'long_lines',
    about = "50 lines of ~2.5 KB, every other changed, under 'synmaxcol'",
    lang = 'lua',
    path = 'treesitter',
    setup = function(repo)
      local old = {}
      for i = 1, 50 do
        old[i] = minified(280) .. ' -- ' .. i
      end
      worktree_change('long.lua', old, edit_every(old, 2))(repo)
    end,
    measure = select_file('long.lua'),
  },
  {
    name = 'minified',
    about = "one changed line of ~400 KB, past 'synmaxcol'",
    lang = 'lua',
    path = 'treesitter',
    setup = function(repo)
      local line = minified(50000)
      worktree_change('min.lua', { line }, { line .. ' ' })(repo)
    end,
    measure = select_file('min.lua'),
  },
  {
    name = 'commit_scss',
    about = 'a commit of 8 scss files of 300 lines, through legacy syntax',
    lang = 'scss',
    path = 'syntax',
    setup = function(repo)
      target_commit(repo, 'target', function()
        for f = 1, 8 do
          repo.write(('s%d.scss'):format(f), scss_lines(300, f))
        end
        repo.commit('init')
        for f = 1, 8 do
          repo.write(('s%d.scss'):format(f), edit_every(scss_lines(300, f), 10))
        end
      end)
    end,
    measure = select_commit('target'),
  },
  {
    name = 'switch_from_huge',
    about = 'a small file selected right after file_huge',
    lang = 'lua',
    path = 'treesitter',
    setup = function(repo)
      worktree_change('huge.lua', huge, huge_edited)(repo)
      repo.write('small.lua', { 'local a = 1' })
    end,
    measure = function(ctx)
      ctx.focus('files')
      ctx.select('huge.lua')
      local t = ctx.select('small.lua')
      return { shown_ms = t.shown, full_ms = t.full }
    end,
  },
  {
    name = 'json_lock',
    about = 'one value changed in a 20,000-line lock file',
    lang = 'json',
    path = 'treesitter',
    requires = 'json',
    setup = function(repo)
      local old = { '{' }
      for i = 1, 5000 do
        vim.list_extend(old, {
          ('  "node_modules/pkg-%d": {'):format(i),
          ('    "version": "1.%d.0",'):format(i % 50),
          ('    "resolved": "https://registry.example/pkg-%d.tgz"'):format(i),
          '  },',
        })
      end
      old[#old + 1] = '}'
      local new = vim.deepcopy(old)
      -- a `"version"` line, the second of the 2500th entry
      new[10003] = new[10003]:gsub('"1%.', '"2.')
      worktree_change('lock.json', old, new)(repo)
    end,
    measure = select_file('lock.json'),
  },
}

--- Pairs of scenarios that differ only in size, whose ratio tells a cost that
--- grows with the size from one that grows faster.
--- @type {small: string, large: string, factor: integer}[]
M.scaling = {
  { small = 'file_rewrite_s', large = 'file_rewrite', factor = 4 },
  { small = 'commit_many_files_s', large = 'commit_many_files', factor = 4 },
}

--- @type table<string, gitview.BenchScenario>
M.by_name = {}
for _, sc in ipairs(M.list) do
  M.by_name[sc.name] = sc
end

return M
