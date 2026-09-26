--- The pieces every other module shares: how the user is told things, how
--- highlight groups are defined, and how a buffer's keys are mapped. They live
--- here so that the one prefix, the one fallback rule and the one reset path are
--- not written twice.
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

--- Define a module's highlight groups.
---
--- The groups are described by a function rather than a table so that they are
--- built against the colorscheme in force at the time: `:colorscheme` clears
--- every group, and the ones derived from `DiffAdd` have to be read again rather
--- than replayed from what was loaded at startup.
---
--- Every group is defined with `default = true`, so a user who sets one of them
--- keeps it.
---
--- @param augroup string name for the ColorScheme subscription
--- @param define fun(set: fun(name: string, val: table))
--- @return {apply: fun(), ensure: fun(), forget: fun()} apply defines the groups
---         now, ensure only if they have never been defined, forget is a testing
---         hook that makes the next ensure define them again
function M.highlights(augroup, define)
  local ready = false
  local function set(name, val)
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', val, { default = true }))
  end
  local function apply()
    define(set)
    if not ready then
      ready = true
      vim.api.nvim_create_autocmd('ColorScheme', {
        group = vim.api.nvim_create_augroup(augroup, { clear = true }),
        callback = apply,
      })
    end
  end
  return {
    apply = apply,
    ensure = function()
      if not ready then
        apply()
      end
    end,
    forget = function()
      ready = false
    end,
  }
end

--- A scratch buffer that forgets itself: when it is wiped out, whatever `states`
--- held for it is dropped, so a module's per-buffer table cannot outlive its
--- buffers.
--- @param filetype string
--- @param states table<integer, any>
--- @return integer bufnr
function M.scratch_buffer(filetype, states)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  -- Registered here rather than wherever the buffer is drawn, which would stack
  -- up one subscription per redraw.
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      states[buf] = nil
    end,
  })
  return buf
end

--- Map normal-mode keys in one buffer, with every description carrying the
--- plugin's prefix so that `:map` and which-key say where a key came from.
--- @param buf integer
--- @return fun(lhs: string, fn: fun(), desc: string, modes?: string[])
function M.buf_mapper(buf)
  return function(lhs, fn, desc, modes)
    vim.keymap.set(modes or 'n', lhs, fn, { buffer = buf, desc = PREFIX .. desc })
  end
end

return M
