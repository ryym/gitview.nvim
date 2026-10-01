if vim.g.loaded_gitview then
  return
end
vim.g.loaded_gitview = true

vim.api.nvim_create_user_command('GitView', function()
  require('gitview').status()
end, {
  desc = 'List every uncommitted change',
})
