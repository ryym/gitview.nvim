--- Everything the user is told goes through here, so that messages carry one
--- prefix and a failed git command always reports its stderr the same way.
local M = {}

local PREFIX = 'unidiff: '

--- @param msg string
function M.info(msg)
  vim.notify(PREFIX .. msg, vim.log.levels.INFO)
end

--- @param msg string
function M.warn(msg)
  vim.notify(PREFIX .. msg, vim.log.levels.WARN)
end

--- How many lines of a command's stderr are worth showing. A failing hook can
--- write hundreds; the first few say what went wrong.
local STDERR_LINES = 5

--- @class unidiff.GitError
--- @field what string the command, as the user would recognise it
--- @field stderr string what it said, possibly empty

--- Report a git command that failed, quoting what it said.
--- @param err unidiff.GitError
function M.git_error(err)
  local msg = PREFIX .. err.what .. ' failed'
  if err.stderr ~= '' then
    local lines = vim.split(err.stderr, '\n', { plain = true })
    local total = #lines
    if total > STDERR_LINES then
      lines = vim.list_slice(lines, 1, STDERR_LINES)
      lines[#lines + 1] = ('... (%d more lines)'):format(total - STDERR_LINES)
    end
    msg = msg .. '\n' .. table.concat(lines, '\n')
  end
  vim.notify(msg, vim.log.levels.ERROR)
end

return M
