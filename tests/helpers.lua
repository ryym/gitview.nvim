--- Helpers for specs that need a real repository.
---
--- Parsers are tested against captured output, which is cheap and exact. What
--- cannot be tested that way is whether the right things were asked of git in
--- the first place, and later, whether a command changed the index the way it
--- was meant to. Those need a repository to look at.
---
--- Loaded with `dofile('tests/helpers.lua')`, since `tests/` is not on the
--- runtimepath and the runner only globs `*_spec.lua`.
local M = {}

--- Kept under `.local/`, which is not tracked, so a crashed run leaves nothing
--- for `git status` to report in the repository under development.
local ROOT = vim.fn.fnamemodify('.local/test-repo', ':p'):gsub('/$', '')

--- @class gitview.TestRepo
--- @field root string absolute path
--- @field git fun(...: string): string run a git command, erroring on failure
--- @field write fun(path: string, lines: string[]) create or overwrite a file
--- @field commit fun(msg: string) stage everything and commit it

--- Run `fn` against a fresh repository, then remove it.
---
--- The repository starts initialised and configured but empty, so a spec
--- decides for itself what HEAD should be — including having no HEAD at all.
---
--- @param fn fun(repo: gitview.TestRepo)
function M.with_repo(fn)
  vim.fn.delete(ROOT, 'rf')
  vim.fn.mkdir(ROOT, 'p')

  local repo = { root = ROOT }

  function repo.git(...)
    local out = vim.system({ 'git', ... }, { cwd = ROOT, text = true }):wait()
    if out.code ~= 0 then
      error(('git %s: %s'):format(table.concat({ ... }, ' '), out.stderr or ''), 2)
    end
    return out.stdout
  end

  function repo.write(path, lines)
    local full = ROOT .. '/' .. path
    vim.fn.mkdir(vim.fs.dirname(full), 'p')
    vim.fn.writefile(lines, full)
  end

  function repo.commit(msg)
    repo.git('add', '-A')
    repo.git('commit', '-qm', msg)
  end

  -- Set locally, so the suite neither reads nor writes the user's own
  -- configuration. Signing is turned off explicitly: a global `commit.gpgsign`
  -- would otherwise make every commit here prompt or fail.
  repo.git('init', '-q')
  repo.git('config', 'user.email', 'test@example.com')
  repo.git('config', 'user.name', 'test')
  repo.git('config', 'commit.gpgsign', 'false')

  local ok, err = pcall(fn, repo)
  vim.fn.delete(ROOT, 'rf')
  if not ok then
    error(err, 0)
  end
end

--- Run `fn` with a directory that is not, and is not inside, a repository.
---
--- It has to live outside the project: every path under it is inside the
--- repository being developed, where git commands succeed and describe that
--- repository instead of failing.
---
--- @param fn fun(dir: string)
function M.with_non_repo(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local ok, err = pcall(fn, dir)
  vim.fn.delete(dir, 'rf')
  if not ok then
    error(err, 0)
  end
end

return M
