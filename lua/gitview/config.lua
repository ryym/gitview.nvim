--- Configuration lives in its own module so that anything building a view can
--- read it without depending on `init`.
local M = {}

--- @class gitview.Config
--- @field context integer unchanged lines left open around each hunk
--- @field algorithm string vim.diff() algorithm
--- @field linematch integer 0 keeps hunks identical to `git diff`; see diff.lines.hunks
--- @field ignore_whitespace boolean where a diff starts out; `:GitView`
---        can turn it on and off while it is open
--- @field list_ratio number share of the width the sidebar of `:GitView` takes
--- @field commit_count integer how many recent commits `:GitView` lists
--- @field commit_ratio number share of the sidebar height the commit list takes
--- @field no_highlight string[] filetypes shown without syntax highlighting

--- @type gitview.Config
M.values = {
  context = 3,
  algorithm = 'histogram',
  linematch = 0,
  ignore_whitespace = false,
  list_ratio = 0.25,
  commit_count = 100,
  commit_ratio = 0.4,
  no_highlight = {},
}

--- @param opts? gitview.Config
function M.set(opts)
  M.values = vim.tbl_extend('force', M.values, opts or {})
end

--- The subset `vim.diff` takes. A fresh table each call, so a caller with state
--- of its own can layer it on top.
--- @param opts gitview.Config
--- @return {algorithm:string, linematch:integer, ignore_whitespace:boolean}
function M.diff_opts(opts)
  return {
    algorithm = opts.algorithm,
    linematch = opts.linematch,
    ignore_whitespace = opts.ignore_whitespace,
  }
end

return M
