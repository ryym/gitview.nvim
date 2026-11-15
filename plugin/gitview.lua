if vim.g.loaded_gitview then
  return
end
vim.g.loaded_gitview = true

vim.api.nvim_create_user_command('Gitview', function(opts)
  require('gitview.command').run(opts.fargs)
end, {
  nargs = '*',
  -- Taken and ignored, so that an action run from visual mode works on the
  -- cursor line rather than failing on the `'<,'>` put in front.
  range = true,
  complete = function(arglead, cmdline)
    return require('gitview.command').complete(arglead, cmdline)
  end,
  desc = 'Open uncommitted changes and recent commits in a tab page, or act on them',
})
