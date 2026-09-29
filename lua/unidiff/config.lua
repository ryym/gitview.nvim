--- Configuration lives in its own module so that anything building a view can
--- read it without depending on `init`.
local M = {}

--- @class unidiff.Config
--- @field context integer unchanged lines left open around each hunk
--- @field algorithm string vim.diff() algorithm
--- @field linematch integer 0 keeps hunks identical to `git diff`; see diff.lines.hunks
--- @field ignore_whitespace boolean where a diff starts out; `:UnidiffStatus`
---        can turn it on and off while it is open
--- @field list_width integer columns for the file list in `:UnidiffStatus`
--- @field commit_count integer how many recent commits `:UnidiffStatus` lists
--- @field commit_ratio number share of the sidebar height the commit list takes
--- @field no_highlight string[] filetypes shown without syntax highlighting

--- @type unidiff.Config
M.values = {
  context = 3,
  algorithm = 'histogram',
  linematch = 0,
  ignore_whitespace = false,
  list_width = 30,
  commit_count = 20,
  commit_ratio = 0.4,
  no_highlight = {},
}

--- @param opts? unidiff.Config
function M.set(opts)
  M.values = vim.tbl_extend('force', M.values, opts or {})
end

--- The subset `vim.diff` takes. A fresh table each call, so a caller with state
--- of its own can layer it on top.
--- @param opts unidiff.Config
--- @return {algorithm:string, linematch:integer, ignore_whitespace:boolean}
function M.diff_opts(opts)
  return {
    algorithm = opts.algorithm,
    linematch = opts.linematch,
    ignore_whitespace = opts.ignore_whitespace,
  }
end

return M
