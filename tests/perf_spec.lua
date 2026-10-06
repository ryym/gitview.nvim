local perf = require('gitview.perf')

local test, eq = _G.test, _G.eq

local LOG = vim.fn.tempname()

--- Run `fn` with the log pointed at a scratch file and both switches off, and
--- return the lines it wrote with their timestamps cut off.
--- @param fn fun()
--- @return string[]
local function logged(fn)
  local file, g, env = perf.file, vim.g.gitview_perf, vim.env.GITVIEW_PERF
  vim.fn.delete(LOG)
  perf.file = LOG
  vim.g.gitview_perf = nil
  vim.env.GITVIEW_PERF = nil
  local ok, err = pcall(fn)
  perf.file, vim.g.gitview_perf, vim.env.GITVIEW_PERF = file, g, env
  if not ok then
    error(err, 0)
  end
  local lines = vim.fn.filereadable(LOG) == 1 and vim.fn.readfile(LOG) or {}
  vim.fn.delete(LOG)
  return vim.tbl_map(function(l)
    -- `12:34:56.789 name 1.2ms k=v` → `name k=v`
    return (l:gsub('^%S+ ', ''):gsub(' [%d.]+ms', ''))
  end, lines)
end

test('perf: writes nothing while off', function()
  eq(
    {},
    logged(function()
      perf.start('a'):finish()
      perf.measure('b', function() end)
    end)
  )
end)

test('perf: vim.g.gitview_perf turns it on', function()
  eq(
    { 'a' },
    logged(function()
      vim.g.gitview_perf = 1
      perf.start('a'):finish()
    end)
  )
end)

test('perf: GITVIEW_PERF turns it on, unless it is 0', function()
  eq(
    { 'a' },
    logged(function()
      vim.env.GITVIEW_PERF = '0'
      perf.start('skipped'):finish()
      vim.env.GITVIEW_PERF = '1'
      perf.start('a'):finish()
    end)
  )
end)

test('perf: a span merges the fields given at start and at finish, once', function()
  eq(
    { 'a dropped=true gen=3 kind=commit' },
    logged(function()
      vim.g.gitview_perf = true
      local span = perf.start('a', { gen = 3, kind = 'commit' })
      span:finish({ dropped = true })
      span:finish()
    end)
  )
end)

test('perf: measure passes through every result, nils included', function()
  local a, b, c
  local lines = logged(function()
    vim.g.gitview_perf = true
    a, b, c = perf.measure('m', function(x)
      return x, nil, 'z'
    end, 'x')
  end)
  eq({ 'm' }, lines)
  eq({ 'x', nil, 'z' }, { a, b, c })
end)
