--- Configuration lives in its own module so that anything building a view can
--- read it without depending on `init`.
local M = {}

--- @class gitview.Config
--- @field diff_context integer unchanged lines left open around each hunk
--- @field diff_algorithm string vim.diff() algorithm
--- @field diff_linematch integer 0 keeps hunks identical to `git diff`; see diff.lines.hunks
--- @field ignore_whitespace boolean where a diff starts out; `:Gitview`
---        can turn it on and off while it is open
--- @field layer gitview.Layer which uncommitted changes `:Gitview` starts out
---        showing: `both`, or `staged` or `unstaged` alone
--- @field sidebar_width_ratio number share of the width the sidebar of `:Gitview` takes
--- @field commit_count integer how many recent commits `:Gitview` lists
--- @field commits_height_ratio number share of the sidebar height the commit list takes
--- @field no_highlight_filetypes string[] filetypes shown without syntax highlighting
--- @field file_list_style 'flat'|'tree' whether the sidebar lists files by their
---        paths alone or as a tree of directories
--- @field default_keymaps boolean whether a session's panes are given the
---        default keys; without them every key is the user's to map

--- @type gitview.Config
M.values = {
  diff_context = 3,
  diff_algorithm = 'histogram',
  diff_linematch = 0,
  ignore_whitespace = false,
  layer = 'both',
  sidebar_width_ratio = 0.25,
  commit_count = 100,
  commits_height_ratio = 0.4,
  no_highlight_filetypes = {},
  file_list_style = 'tree',
  default_keymaps = true,
}

--- @param opts? gitview.Config
function M.set(opts)
  M.values = vim.tbl_extend('force', M.values, opts or {})
end

--- The subset `vim.diff` takes, under its own key names. A fresh table each
--- call, so a caller with state of its own can layer it on top.
--- @param opts gitview.Config
--- @return {algorithm:string, linematch:integer, ignore_whitespace:boolean}
function M.diff_opts(opts)
  return {
    algorithm = opts.diff_algorithm,
    linematch = opts.diff_linematch,
    ignore_whitespace = opts.ignore_whitespace,
  }
end

return M
