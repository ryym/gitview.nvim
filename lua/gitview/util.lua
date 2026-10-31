--- The pieces every other module shares: how the user is told things, how
--- highlight groups are defined, and how a buffer's keys are mapped. They live
--- here so that the one prefix, the one fallback rule and the one reset path are
--- not written twice.
local M = {}

local PREFIX = 'gitview: '

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

--- @class gitview.GitError
--- @field what string the command, as the user would recognise it
--- @field stderr string what it said, possibly empty

--- Report a git command that failed, quoting what it said.
--- @param err gitview.GitError
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

--- Give a window the options the plugin draws itself with.
---
--- Set for this window and buffer alone, which is what keeps them from spreading:
--- a window remembers a window-local option per buffer, so the gutter and the
--- winbar go away as soon as the window shows something else, and a `:tabnew`
--- opened from here starts with the user's own values. `vim.wo` cannot be used
--- for this, since it acts like `:set` for an option that is not global-local and
--- so writes the global value too, which every later window would inherit.
---
--- @param win integer
--- @param options table<string, any>
function M.configure_window_options(win, options)
  for name, value in pairs(options) do
    vim.api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end
end

--- A scratch buffer that forgets itself: when it is wiped out, whatever `states`
--- held for it is dropped, so a module's per-buffer table cannot outlive its
--- buffers.
---
--- It is given no filetype, which is left to whoever shows it: `FileType` runs
--- in a window showing the buffer, if there is one in the tab page, and an
--- ftplugin setting window options sets them there.
--- @param states table<integer, any>
--- @return integer bufnr
function M.scratch_buffer(states)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
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
---
--- `nowait`, so a key fires at once even where a global mapping starts with
--- it. Otherwise Vim waits 'timeoutlen' for the rest of the longer one, and a
--- key typed soon enough after it runs that mapping instead: `m` then `d` in
--- the commits pane would be someone's `md`, editing a buffer that cannot be
--- modified.
--- @param buf integer
--- @return fun(lhs: string, fn: fun(), desc: string, modes?: string[])
function M.buf_mapper(buf)
  return function(lhs, fn, desc, modes)
    vim.keymap.set(modes or 'n', lhs, fn, { buffer = buf, desc = PREFIX .. desc, nowait = true })
  end
end

--- Do what a key would do outside a buffer that maps it for itself: run the
--- global mapping of `lhs`, or nothing when there is none.
---
--- A buffer-local map hides the global one for good; this is how such a map
--- passes the key on when it has nothing to do with it. A mapping whose
--- right-hand side names a script-local `<SID>` function cannot be run from
--- here, and is skipped.
--- @param mode string
--- @param lhs string
function M.run_global_map(mode, lhs)
  local key = vim.keycode(lhs)
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if vim.keycode(m.lhs) == key then
      local keys
      if m.callback then
        local out = m.callback()
        keys = m.expr == 1 and out or nil
      elseif not m.rhs:find('<SID>', 1, true) then
        keys = m.expr == 1 and vim.api.nvim_eval(m.rhs) or m.rhs
      end
      if type(keys) == 'string' and keys ~= '' then
        vim.api.nvim_feedkeys(vim.keycode(keys), m.noremap == 1 and 'n' or 'm', false)
      end
      return
    end
  end
end

--- Make text safe to put in a 'winbar' or 'statusline': a literal `%` there
--- starts an item, so it has to be doubled.
--- @param text string
--- @return string
function M.escape_statusline(text)
  return (text:gsub('%%', '%%%%'))
end

--- `n` of something, named in the plural unless there is one of it.
--- @param n integer
--- @param what string singular
--- @return string
function M.counted(n, what)
  return ('%d %s%s'):format(n, what, n == 1 and '' or 's')
end

return M
