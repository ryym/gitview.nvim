local config = require('gitview.config')

local M = {}

--- Takes effect for sessions opened afterwards. Called more than once, each
--- call is merged over the ones before.
--- @param opts? gitview.Config
function M.setup(opts)
  config.set(opts)
end

--- Open a tab page listing uncommitted changes and recent commits, or go to the
--- one already open for the repository.
---
--- The session is required here rather than at the top, so that requiring this
--- from a user's configuration loads nothing until a session is opened.
--- @return gitview.Session?
function M.open()
  return require('gitview.ui.session').open()
end

return M
