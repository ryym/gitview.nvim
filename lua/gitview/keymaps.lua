--- The keys each pane of a session is given by default, every one of them mapped
--- to an action; see `gitview.actions`.
---
--- They are mapped in the panes' buffers as a session opens them, before their
--- filetype is set, so that a user mapping the same key from a `FileType`
--- autocommand or an ftplugin always does so after, and wins.
local actions = require('gitview.actions')
local config = require('gitview.config')
local keymap = require('gitview.diff.keymap')
local util = require('gitview.util')

local M = {}

--- @class gitview.DefaultKey
--- @field [1] string lhs
--- @field [2] fun(): boolean? what it does
--- @field [3] string what it does, for `:map`
--- @field modes? string[] normal mode alone when not given
--- @field fallback? boolean pass the key on to its global mapping when the
---        action does nothing, which the buffer's mapping hides otherwise

--- The keys every pane has, all of them acting on the whole session. `gw` and
--- `gs` change what the diff shows wherever the cursor happens to be. `gw`
--- shadows the format operator and `gs` `:sleep`, neither of which means
--- anything in a buffer that cannot be modified.
--- @type gitview.DefaultKey[]
local SHARED = {
  { 'q', actions.close, 'close' },
  { 'R', actions.refresh, 'refresh' },
  { 'gw', actions.toggle_ignore_whitespace, 'toggle ignoring whitespace' },
  { 'gs', actions.cycle_layer, 'show both layers, staged alone or unstaged alone' },
}

--- The modes of the keys whose actions take a visual selection. They are
--- mapped in both in every pane that maps them, the panes where they only say
--- why they do nothing included, so that a selection never reaches the key's
--- own meaning in a buffer that cannot be modified.
local NX = { 'n', 'x' }

--- @type table<gitview.Pane, gitview.DefaultKey[]>
local PANES = {
  files = {
    { 'gf', actions.open_file, 'open the file under the cursor in the previous tab page' },
    { '<CR>', actions.focus_diff, 'focus the diff' },
    { '<BS>', actions.end_review, 'end the review', fallback = true },
    -- Point `gr` to the commits pane, where the ranges are chosen, rather than
    -- leave it to Neovim's own `gr` keys.
    { 'gr', actions.start_review, 'nothing to review here' },
    { 'x', actions.toggle_check, 'check off the files under review selected', modes = NX },
    -- `s` and `u` rather than one key toggling: a file with changes on both
    -- sides has no obvious sense in which it is on or off, and a row here
    -- states that state rather than hiding it, so the direction is given
    -- explicitly.
    { 's', actions.stage, 'stage the file or directory under the cursor', modes = NX },
    { 'u', actions.unstage, 'unstage the file or directory under the cursor', modes = NX },
  },

  -- Separating the panes is what lets each one carry only the keys that mean
  -- something in it. `s`, `u` and `x` are the exception: they are mapped in
  -- order to say why they do nothing, since leaving them unmapped would let
  -- them reach a buffer that cannot be modified and error, in visual mode too.
  commits = {
    { 'gf', actions.open_file, 'open the file under the cursor in the previous tab page' },
    {
      '<CR>',
      function()
        -- On a commit there is somewhere further in to go; on one of its
        -- files the row already names what the diff is showing.
        return actions.look_into() or actions.focus_diff()
      end,
      'look into the commit or range, or focus the diff',
    },
    { '<BS>', actions.back_out, 'back out of the commit', fallback = true },
    { 'm', actions.start_range, 'mark this commit as the far end of a range' },
    -- `g` and a letter, as the other keys that change what the session is
    -- doing rather than act on a row. Mapped with `<nowait>`, so that Neovim's
    -- own `grn` and the like do not hold it up.
    { 'gr', actions.start_review, 'review the commit or range' },
    -- `<Esc>` is commonly mapped already, to `:nohlsearch` above all, and this
    -- map hides it in the pane: with no range to clear it does what it would
    -- have done.
    { '<Esc>', actions.clear_range, 'clear the range', fallback = true },
    { 's', actions.stage, 'nothing to stage here', modes = NX },
    { 'u', actions.unstage, 'nothing to stage here', modes = NX },
    { 'x', actions.toggle_check, 'nothing to check off here', modes = NX },
  },

  diff = {
    { ']c', actions.next_hunk, 'next hunk' },
    { '[c', actions.prev_hunk, 'previous hunk' },
    { ']f', actions.next_file, 'next file' },
    { '[f', actions.prev_file, 'previous file' },
    { ']r', actions.next_commit, 'next commit, the older one' },
    { '[r', actions.prev_commit, 'previous commit, the newer one' },
    { 'gf', actions.open_file, 'open the file the cursor is in' },
    { 'gy', actions.copy_location, 'copy the files and lines selected', modes = NX },
    -- Inside the diff, `s` and `u` work on lines rather than on the whole file:
    -- the rows under the cursor or the visual selection, and with a capital,
    -- the whole change the cursor is in.
    { 's', actions.stage, 'stage the selected lines', modes = NX },
    { 'u', actions.unstage, 'unstage the selected lines', modes = NX },
    { 'S', actions.stage_hunk, 'stage this hunk' },
    { 'U', actions.unstage_hunk, 'unstage this hunk' },
    { 'x', actions.toggle_check, 'check off the file under review the cursor is in', modes = NX },
    { ']x', actions.next_unread, 'next file still to be read' },
    { '[x', actions.prev_unread, 'previous file still to be read' },
  },
}

-- No action of their own: they open folds as Neovim does, but for a file's
-- first fold, and so take the key they replace; see `keymap.open_fold`.
for _, key in ipairs({ 'zo', 'zO', 'za', 'zA' }) do
  table.insert(PANES.diff, {
    key,
    function()
      keymap.open_fold(vim.api.nvim_get_current_buf(), key)
    end,
    ("%s, keeping the change in view on a file's first fold"):format(key),
  })
end

--- @param buf integer
--- @param keys gitview.DefaultKey[]
local function map_all(buf, keys)
  local map = util.buf_mapper(buf)
  for _, k in ipairs(keys) do
    local lhs, fn = k[1], k[2]
    if k.fallback then
      local action = fn
      fn = function()
        if not action() then
          util.run_global_map('n', lhs)
        end
      end
    end
    map(lhs, fn, k[3], k.modes)
  end
end

--- Map the default keys in each pane of a session, unless they are turned off.
--- @param s gitview.Session
function M.set(s)
  if not config.values.default_keymaps then
    return
  end
  for pane, buf in pairs({ files = s.files_buf, commits = s.commits_buf, diff = s.diff_buf }) do
    map_all(buf, SHARED)
    map_all(buf, PANES[pane])
  end
end

return M
