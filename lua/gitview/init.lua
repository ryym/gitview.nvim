local config = require('gitview.config')
local session = require('gitview.ui.session')

local M = {}

--- @param opts? gitview.Config
function M.setup(opts)
  config.set(opts)
end

--- Open a tab page listing every uncommitted change.
--- @return gitview.Session?
function M.status()
  return session.open()
end

return M
