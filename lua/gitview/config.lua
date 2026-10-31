--- Configuration lives in its own module so that anything building a view can
--- read it without depending on `init`.
local M = {}

--- @class gitview.Config
--- @field context integer unchanged lines left open around each hunk
--- @field algorithm string vim.diff() algorithm
--- @field linematch integer 0 keeps hunks identical to `git diff`; see diff.lines.hunks
--- @field ignore_whitespace boolean where a diff starts out; `:GitView`
---        can turn it on and off while it is open
--- @field layer gitview.Layer which uncommitted changes `:GitView` starts out
---        showing: `both`, or `staged` or `unstaged` alone
--- @field list_ratio number share of the width the sidebar of `:GitView` takes
--- @field commit_count integer how many recent commits `:GitView` lists
--- @field commit_ratio number share of the sidebar height the commit list takes
--- @field no_highlight string[] filetypes shown without syntax highlighting
--- @field list_style 'flat'|'tree' whether the sidebar lists files by their
---        paths alone or as a tree of directories
--- @field default_keymaps boolean whether a session's panes are given the
---        default keys; without them every key is the user's to map

--- @type gitview.Config
M.values = {
  context = 3,
  algorithm = 'histogram',
  linematch = 0,
  ignore_whitespace = false,
  layer = 'both',
  list_ratio = 0.25,
  commit_count = 100,
  commit_ratio = 0.4,
  no_highlight = {},
  list_style = 'flat',
  default_keymaps = true,
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
