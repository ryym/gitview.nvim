local perf = require('unidiff.perf')

local test, eq = _G.test, _G.eq

local LOG = vim.fn.fnamemodify('.local/test-perf.log', ':p')

--- Run `fn` with the log pointed at a scratch file and both switches off, and
--- return the lines it wrote with their timestamps cut off.
--- @param fn fun()
--- @return string[]
local function logged(fn)
  local file, g, env = perf.file, vim.g.unidiff_perf, vim.env.UNIDIFF_PERF
  vim.fn.mkdir(vim.fs.dirname(LOG), 'p')
  vim.fn.delete(LOG)
  perf.file = LOG
  vim.g.unidiff_perf = nil
  vim.env.UNIDIFF_PERF = nil
  local ok, err = pcall(fn)
  perf.file, vim.g.unidiff_perf, vim.env.UNIDIFF_PERF = file, g, env
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

test('perf: vim.g.unidiff_perf turns it on', function()
  eq(
    { 'a' },
    logged(function()
      vim.g.unidiff_perf = 1
      perf.start('a'):finish()
    end)
  )
end)

test('perf: UNIDIFF_PERF turns it on, unless it is 0', function()
  eq(
    { 'a' },
    logged(function()
      vim.env.UNIDIFF_PERF = '0'
      perf.start('skipped'):finish()
      vim.env.UNIDIFF_PERF = '1'
      perf.start('a'):finish()
    end)
  )
end)

test('perf: a span merges the fields given at start and at finish, once', function()
  eq(
    { 'a dropped=true gen=3 kind=commit' },
    logged(function()
      vim.g.unidiff_perf = true
      local span = perf.start('a', { gen = 3, kind = 'commit' })
      span:finish({ dropped = true })
      span:finish()
    end)
  )
end)

test('perf: measure passes through every result, nils included', function()
  local a, b, c
  local lines = logged(function()
    vim.g.unidiff_perf = true
    a, b, c = perf.measure('m', function(x)
      return x, nil, 'z'
    end, 'x')
  end)
  eq({ 'm' }, lines)
  eq({ 'x', nil, 'z' }, { a, b, c })
end)
