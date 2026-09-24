if vim.g.loaded_unidiff then
  return
end
vim.g.loaded_unidiff = true

local function revs()
  return { 'HEAD', 'HEAD~1', 'HEAD~2', 'main', 'master' }
end

vim.api.nvim_create_user_command('Unidiff', function(cmd)
  require('unidiff').open({ rev = cmd.args ~= '' and cmd.args or nil })
end, {
  nargs = '?',
  complete = revs,
  desc = 'Open a unified diff of the current buffer against a revision',
})

vim.api.nvim_create_user_command('UnidiffAll', function(cmd)
  require('unidiff').open_all({ rev = cmd.args ~= '' and cmd.args or nil })
end, {
  nargs = '?',
  complete = revs,
  desc = 'Open a unified diff of every changed file against a revision',
})

vim.api.nvim_create_user_command('UnidiffStatus', function()
  require('unidiff').status()
end, {
  desc = 'List every uncommitted change',
})

vim.api.nvim_create_user_command('UnidiffMixed', function()
  require('unidiff').open_mixed()
end, {
  desc = 'Experimental: every uncommitted change, with staged lines marked',
})
