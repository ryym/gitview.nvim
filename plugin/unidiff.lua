if vim.g.loaded_unidiff then
  return
end
vim.g.loaded_unidiff = true

vim.api.nvim_create_user_command('Unidiff', function(cmd)
  require('unidiff').open({ rev = cmd.args ~= '' and cmd.args or nil })
end, {
  nargs = '?',
  complete = function()
    return { 'HEAD', 'HEAD~1', 'HEAD~2', 'main', 'master' }
  end,
  desc = 'Open a unified diff of the current buffer against a revision',
})
