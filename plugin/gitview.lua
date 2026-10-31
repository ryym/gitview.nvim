if vim.g.loaded_gitview then
  return
end
vim.g.loaded_gitview = true

vim.api.nvim_create_user_command('GitView', function(opts)
  require('gitview.command').run(opts.fargs)
end, {
  nargs = '*',
  complete = function(arglead, cmdline)
    return require('gitview.command').complete(arglead, cmdline)
  end,
  desc = 'Open uncommitted changes and recent commits in a tab page, or act on them',
})
