--- The subcommands of `:Gitview`.
---
--- Only what acts on a whole session is here, and nothing that depends on where
--- the cursor is: those are actions to map keys to rather than commands to type.
--- With no argument a subcommand goes round, or toggles, and with one it sets.
---
--- Nothing heavy is required at the top, so that completing a subcommand loads
--- nothing more than this.
local M = {}

--- @class gitview.Subcommand
--- @field run fun(arg: string?) the argument one of `args`, if given
--- @field args? string[] what the one argument it takes may be, if any

--- @type table<string, gitview.Subcommand>
local SUBCOMMANDS = {
  open = {
    run = function()
      require('gitview').open()
    end,
  },
  close = {
    run = function()
      require('gitview.actions').close()
    end,
  },
  refresh = {
    run = function()
      require('gitview.actions').refresh()
    end,
  },
  ['shown-changes'] = {
    args = { 'both', 'staged', 'unstaged' },
    run = function(arg)
      local actions = require('gitview.actions')
      if arg then
        actions.set_shown_changes(arg --[[@as gitview.Layer]])
      else
        actions.cycle_shown_changes()
      end
    end,
  },
  whitespace = {
    args = { 'on', 'off' },
    run = function(arg)
      local actions = require('gitview.actions')
      if arg then
        actions.set_ignore_whitespace(arg == 'on')
      else
        actions.toggle_ignore_whitespace()
      end
    end,
  },
}

--- @param msg string
local function error_out(msg)
  vim.notify('gitview: ' .. msg, vim.log.levels.ERROR)
end

--- Run `:Gitview` with its arguments; none opens a session.
--- @param fargs string[]
function M.run(fargs)
  local name = fargs[1] or 'open'
  local sub = SUBCOMMANDS[name]
  if not sub then
    error_out(('no such subcommand: %s'):format(name))
    return
  end
  local arg = fargs[2]
  if #fargs > (sub.args and 2 or 1) then
    error_out(('too many arguments to %s'):format(name))
    return
  end
  if arg and not vim.list_contains(sub.args, arg) then
    error_out(('%s takes %s, not %s'):format(name, table.concat(sub.args, ' or '), arg))
    return
  end
  -- Said here rather than left to the action, which says nothing when there is
  -- no session, as a key mapped to it would want.
  if name ~= 'open' and not require('gitview.ui.session').current() then
    vim.notify('gitview: no session in this tab page', vim.log.levels.INFO)
    return
  end
  sub.run(arg)
end

--- What the argument being typed may be completed to.
--- @param arglead string
--- @param cmdline string
--- @return string[]
function M.complete(arglead, cmdline)
  -- The words before the one being typed, the command's name among them.
  local before = vim.split(vim.trim(cmdline:sub(1, #cmdline - #arglead)), '%s+')
  local candidates
  if #before == 1 then
    candidates = vim.tbl_keys(SUBCOMMANDS)
    table.sort(candidates)
  elseif #before == 2 then
    local sub = SUBCOMMANDS[before[2]]
    candidates = sub and sub.args or {}
  else
    candidates = {}
  end
  return vim.tbl_filter(function(c)
    return vim.startswith(c, arglead)
  end, candidates)
end

return M
