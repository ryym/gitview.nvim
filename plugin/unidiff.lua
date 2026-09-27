if vim.g.loaded_unidiff then
  return
end
vim.g.loaded_unidiff = true

vim.api.nvim_create_user_command('UnidiffStatus', function()
  require('unidiff').status()
end, {
  desc = 'List every uncommitted change',
})
