--- Configuration lives in its own module so that anything building a view can
--- read it without depending on `init`, which depends on everything.
local M = {}

--- @class unidiff.Config
--- @field context integer unchanged lines kept around each hunk
--- @field rev string default revision to diff against
--- @field algorithm string vim.diff() algorithm
--- @field linematch integer 0 keeps hunks identical to `git diff`; see diff.lines.hunks
--- @field list_width integer columns for the file list in `:UnidiffStatus`
--- @field commit_count integer how many recent commits `:UnidiffStatus` lists

--- @type unidiff.Config
M.values = {
  context = 3,
  rev = 'HEAD',
  algorithm = 'histogram',
  linematch = 0,
  list_width = 30,
  commit_count = 20,
}

--- @param opts? unidiff.Config
function M.set(opts)
  M.values = vim.tbl_extend('force', M.values, opts or {})
end

--- Fill in whatever a single call did not override.
--- @generic T: table
--- @param opts T?
--- @return T
function M.resolve(opts)
  return vim.tbl_extend('keep', opts or {}, M.values)
end

--- The subset `vim.diff` takes.
--- @param opts unidiff.Config
--- @return {algorithm:string, linematch:integer}
function M.diff_opts(opts)
  return { algorithm = opts.algorithm, linematch = opts.linematch }
end

return M
