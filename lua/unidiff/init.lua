local config = require('unidiff.config')
local session = require('unidiff.ui.session')

local M = {}

--- @param opts? unidiff.Config
function M.setup(opts)
  config.set(opts)
end

--- Open a tab page listing every uncommitted change.
--- @return unidiff.Session?
function M.status()
  return session.open()
end

return M
