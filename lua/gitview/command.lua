--- The subcommands of `:Gitview`.
---
--- Only what acts on a whole session is here, and nothing that depends on where
--- the cursor is: those are actions to map keys to rather than commands to type.
--- A setting's subcommand goes round, or toggles, with no argument, and sets
--- with one.
---
--- Nothing heavy is required at the top, so that completing a subcommand loads
--- nothing more than this.
local M = {}

--- @class gitview.Subcommand
--- @field run fun(args: string[]) the arguments, as many as it takes
--- @field args? string[] what the one argument it takes may be, if it takes one
---        from a fixed set
--- @field refs? true takes `<base> [<new>]` instead
--- @field opens? true opens a session rather than needing one

--- @type table<string, gitview.Subcommand>
local SUBCOMMANDS = {
  open = {
    opens = true,
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
    run = function(args)
      local actions = require('gitview.actions')
      if args[1] then
        actions.set_shown_changes(args[1] --[[@as gitview.Layer]])
      else
        actions.cycle_shown_changes()
      end
    end,
  },
  whitespace = {
    args = { 'on', 'off' },
    run = function(args)
      local actions = require('gitview.actions')
      if args[1] then
        actions.set_ignore_whitespace(args[1] == 'on')
      else
        actions.toggle_ignore_whitespace()
      end
    end,
  },
  review = {
    refs = true,
    opens = true,
    run = function(args)
      require('gitview.ui.session').review_refs(args[1], args[2])
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
  local args = vim.list_slice(fargs, 2)
  if sub.refs then
    if #args < 1 or #args > 2 then
      error_out(('usage: :Gitview %s <base> [<new>]'):format(name))
      return
    end
  elseif #args > (sub.args and 1 or 0) then
    error_out(('too many arguments to %s'):format(name))
    return
  elseif args[1] and not vim.list_contains(sub.args, args[1]) then
    error_out(('%s takes %s, not %s'):format(name, table.concat(sub.args, ' or '), args[1]))
    return
  end
  -- Said here rather than left to the action, which says nothing when there is
  -- no session, as a key mapped to it would want.
  if not sub.opens and not require('gitview.ui.session').current() then
    vim.notify('gitview: no session in this tab page', vim.log.levels.INFO)
    return
  end
  sub.run(args)
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
