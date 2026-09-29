--- Timings of the steps a reader waits on, written to a log for whoever is
--- working on the plugin. Off unless `vim.g.unidiff_perf` is set or `UNIDIFF_PERF`
--- is in the environment.
---
--- Both are read on every call rather than once at startup, so that
--- `:let g:unidiff_perf = 1` in a running session turns it on. Off, a call costs
--- that one check.
---
--- The lines go to a file rather than through `vim.notify`: one per cursor move
--- would bury every other message, and drawing them would slow down what is
--- being measured.
local M = {}

--- Where the lines go. Replaceable, so that a test does not write into the
--- developer's own log.
M.file = vim.fs.joinpath(vim.fn.stdpath('log'), 'unidiff-perf.log')

--- @return boolean
function M.enabled()
  local g = vim.g.unidiff_perf
  if g ~= nil and g ~= false and g ~= 0 then
    return true
  end
  local env = vim.env.UNIDIFF_PERF
  return env ~= nil and env ~= '' and env ~= '0'
end

--- @param fields table<string, any>?
--- @return string
local function format_fields(fields)
  if not fields then
    return ''
  end
  local keys = vim.tbl_keys(fields)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = ('%s=%s'):format(k, tostring(fields[k]))
  end
  return ' ' .. table.concat(parts, ' ')
end

--- @param name string
--- @param ms number
--- @param fields table<string, any>?
local function write(name, ms, fields)
  local sec, usec = vim.uv.gettimeofday()
  local line = ('%s.%03d %s %.1fms%s\n'):format(
    os.date('%H:%M:%S', sec),
    math.floor(usec / 1000),
    name,
    ms,
    format_fields(fields)
  )
  -- Opened for each line rather than held: a handle kept open would outlive a
  -- change of `M.file`, and a line costs microseconds against the milliseconds
  -- it reports.
  local f = io.open(M.file, 'a')
  if f then
    f:write(line)
    f:close()
  end
end

--- @class unidiff.PerfSpan
--- @field finish fun(self: unidiff.PerfSpan, fields: table<string, any>?)

--- What `start` hands out while logging is off, so that callers need no check of
--- their own.
--- @type unidiff.PerfSpan
local NOOP = { finish = function() end }

--- Start timing something that may end in another callback, such as a draw
--- held back by a timer.
---
--- The line is written when the span finishes, with the fields given here and
--- there merged; a span finished twice writes once.
---
--- @param name string
--- @param fields table<string, any>?
--- @return unidiff.PerfSpan
function M.start(name, fields)
  if not M.enabled() then
    return NOOP
  end
  local t0 = vim.uv.hrtime()
  local done = false
  return {
    finish = function(_, more)
      if done then
        return
      end
      done = true
      local ms = (vim.uv.hrtime() - t0) / 1e6
      write(name, ms, more and vim.tbl_extend('force', fields or {}, more) or fields)
    end,
  }
end

--- Time a call made and finished here, and return what it returns.
--- @generic T
--- @param name string
--- @param fn fun(...): T
--- @param ... any passed to `fn`
--- @return T
function M.measure(name, fn, ...)
  if not M.enabled() then
    return fn(...)
  end
  local t0 = vim.uv.hrtime()
  local results = vim.F.pack_len(fn(...))
  write(name, (vim.uv.hrtime() - t0) / 1e6)
  return vim.F.unpack_len(results)
end

return M
