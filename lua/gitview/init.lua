local config = require('gitview.config')
local session = require('gitview.ui.session')

local M = {}

--- @param opts? gitview.Config
function M.setup(opts)
  config.set(opts)
end

--- Open a tab page listing uncommitted changes and recent commits.
--- @return gitview.Session?
function M.open()
  return session.open()
end

return M
