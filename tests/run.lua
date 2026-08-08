-- Minimal test runner: `make test` (or nvim --headless -l tests/run.lua).
local failures, total = 0, 0

--- @param name string
--- @param fn fun()
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    io.write(('  ok   %s\n'):format(name))
  else
    failures = failures + 1
    io.write(('  FAIL %s\n       %s\n'):format(name, tostring(err)))
  end
end

local function eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(
      ('%s\n  expected: %s\n  actual:   %s'):format(
        msg or 'mismatch',
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

_G.test, _G.eq = test, eq

for _, file in ipairs(vim.fn.glob('tests/*_spec.lua', false, true)) do
  io.write(file .. '\n')
  dofile(file)
end

io.write(('\n%d tests, %d failures\n'):format(total, failures))
if failures > 0 then
  vim.cmd('cquit 1')
end
