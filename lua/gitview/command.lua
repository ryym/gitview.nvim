--- The subcommands of `:Gitview`.
---
--- `run` runs any action, so that each needs no subcommand of its own. The
--- others are what is no action: opening a session, with no subcommand, and
--- reviewing between refs.
---
--- Nothing heavy is required at the top, so that completing a subcommand loads
--- nothing more than this. Completing a ref runs git, and loads only the module
--- that runs it.
local M = {}

--- @param msg string
local function error_out(msg)
  vim.notify('gitview: ' .. msg, vim.log.levels.ERROR)
end

--- The options of an action from `key=value` words. `true` and `false` become
--- booleans, and any other value stays a string: the command does not know
--- what type an option takes. A bare `key` is short for `key=true`.
--- @param words string[]
--- @return table? opts nil when a word is no option
--- @return string? word the word that is no option
local function parse_options(words)
  local opts = {}
  for _, word in ipairs(words) do
    local key, value = word:match('^([^=]+)=(.*)$')
    if not key then
      key, value = word:match('^([^=]+)$'), 'true'
    end
    if not key then
      return nil, word
    end
    if value == 'true' then
      opts[key] = true
    elseif value == 'false' then
      opts[key] = false
    else
      opts[key] = value
    end
  end
  return opts
end

--- Run the action `args[1]` with the options in the rest.
--- @param args string[]
local function run_action(args)
  local name = args[1]
  if not name then
    error_out('usage: :Gitview run <action> [<key>=<value> ...]')
    return
  end
  local actions = require('gitview.actions')
  local fn = actions[name]
  if not fn then
    error_out(('no such action: %s'):format(name))
    return
  end
  local opts, bad = parse_options(vim.list_slice(args, 2))
  if not opts then
    error_out(('not an option: %s'):format(bad))
    return
  end
  -- An action of no options would ignore them, so they are refused here.
  if next(opts) and debug.getinfo(fn, 'u').nparams == 0 then
    error_out(('%s takes no options'):format(name))
    return
  end
  -- Said here rather than left to the action, which says nothing when there is
  -- no session, as a key mapped to it would want.
  if not require('gitview.ui.session').current() then
    vim.notify('gitview: no session in this tab page', vim.log.levels.INFO)
    return
  end
  -- Called bare, so that an option the action refuses is raised with a stack
  -- trace like a bug. Telling the two apart is not worth the complexity.
  fn(opts)
end

--- @class gitview.Subcommand
--- @field run fun(args: string[]) the arguments, as many as it takes
--- @field complete fun(before: string[]): string[] what the argument being
---        typed may be, given the arguments before it

--- What a ref may be completed to: `HEAD`, then the branches and the tags of
--- the repository the command would act on.
--- @return string[]
local function ref_candidates()
  local git = require('gitview.git')
  -- Look for the session only when its module is loaded already, which it is
  -- whenever there is one, so that completing loads nothing for it.
  local session = package.loaded['gitview.ui.session']
  local s = session and session.current()
  local root = s and s.root or git.current_root()
  local names = root and git.ref_names(root) or {}
  table.insert(names, 1, 'HEAD')
  return names
end

--- @type table<string, gitview.Subcommand>
local SUBCOMMANDS = {
  run = {
    run = run_action,
    complete = function(before)
      if #before > 0 then
        return {}
      end
      local names = vim.tbl_keys(require('gitview.actions'))
      table.sort(names)
      return names
    end,
  },
  review = {
    run = function(args)
      if #args < 1 or #args > 2 then
        error_out('usage: :Gitview review <base> [<new>]')
        return
      end
      require('gitview.ui.session').review_refs(args[1], args[2])
    end,
    complete = function(before)
      return #before < 2 and ref_candidates() or {}
    end,
  },
}

--- Run `:Gitview` with its arguments; none opens a session.
--- @param fargs string[]
function M.run(fargs)
  if #fargs == 0 then
    require('gitview').open()
    return
  end
  local sub = SUBCOMMANDS[fargs[1]]
  if not sub then
    error_out(('no such subcommand: %s'):format(fargs[1]))
    return
  end
  sub.run(vim.list_slice(fargs, 2))
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
  else
    local sub = SUBCOMMANDS[before[2]]
    candidates = sub and sub.complete(vim.list_slice(before, 3)) or {}
  end
  return vim.tbl_filter(function(c)
    return vim.startswith(c, arglead)
  end, candidates)
end

return M
