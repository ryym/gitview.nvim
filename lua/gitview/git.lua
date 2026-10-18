local perf = require('gitview.perf')

local M = {}

--- @class gitview.Change
--- @field status 'A'|'M'|'D'|'R'|'C'|'T'|'U' `U` is an unmerged path
--- @field path string repo-relative path in the working tree
--- @field old_path string repo-relative path in the revision (differs on rename)
--- @field binary boolean

--- Split blob contents into lines. An empty blob is an empty file, so it has no
--- lines at all; `vim.split` would otherwise report a single empty one and the
--- diff would show a phantom line.
--- @param text string
--- @return string[]
local function blob_lines(text)
  if text == '' then
    return {}
  end
  return vim.split((text:gsub('\n$', '')), '\n', { plain = true })
end

--- @class gitview.GitResult
--- @field ok boolean
--- @field stdout string
--- @field stderr string what to show the user when `ok` is false

--- The coroutines started by `M.async`, each with the function that resumes it.
--- Weak, so that a coroutine abandoned mid-way does not stay alive through here.
--- @type table<thread, fun(out: vim.SystemCompleted)>
local async_threads = setmetatable({}, { __mode = 'k' })

--- Every subprocess goes through here, so that stderr is never thrown away and
--- so that one place decides whether a call blocks.
---
--- Inside `M.async` it does not: the coroutine yields until the process exits
--- and Neovim goes on running meanwhile. Anywhere else it waits, which is what
--- every caller that needs the answer before it can go on wants.
---
--- @param cmd string[]
--- @param cwd string
--- @param opts? table extra `vim.system` options; `text = false` reads stdout raw
--- @return gitview.GitResult
function M.run(cmd, cwd, opts)
  local sys = vim.tbl_extend('force', { text = true, cwd = cwd }, opts or {})
  local resume = async_threads[coroutine.running()]
  -- The subcommand and its first argument say which of the calls a view makes
  -- this was; the rest is revisions and paths.
  local span = perf.start('git', { cmd = table.concat(cmd, ' ', 2, math.min(#cmd, 3)) })
  local out --- @type vim.SystemCompleted
  if resume then
    vim.system(cmd, sys, function(done)
      vim.schedule(function()
        resume(done)
      end)
    end)
    out = coroutine.yield()
  else
    out = vim.system(cmd, sys):wait()
  end
  span:finish()
  return {
    ok = out.code == 0,
    stdout = out.stdout or '',
    stderr = vim.trim(out.stderr or ''),
  }
end

--- Run `fn` without blocking on the git commands it runs, and hand what it
--- returns to `done`.
---
--- `fn` is ordinary synchronous code: every `M.run` inside it yields rather than
--- waits. So `done` may be called before this returns, when `fn` runs no command.
--- Between commands the rest of Neovim runs, so by the time `done` is called the
--- editor may be in any state; checking that the result is still wanted is the
--- caller's business.
---
--- @param fn fun(): ...
--- @param done fun(...)
function M.async(fn, done)
  local co = coroutine.create(fn)
  local function finish(ok, ...)
    if not ok then
      error(debug.traceback(co, (...)), 0)
    end
    if coroutine.status(co) == 'dead' then
      done(...)
    end
  end
  async_threads[co] = function(out)
    finish(coroutine.resume(co, out))
  end
  finish(coroutine.resume(co))
end

--- @param cwd string
--- @return string? root absolute path of the repository root
function M.root(cwd)
  local res = M.run({ 'git', 'rev-parse', '--show-toplevel' }, cwd)
  return res.ok and vim.trim(res.stdout) or nil
end

--- @param cwd string
--- @return string? dir absolute path of the directory git keeps the repository in
function M.dir(cwd)
  -- Neither the location nor the shape of the git directory follows from the
  -- root: `.git` is a file pointing elsewhere in a worktree and in a submodule,
  -- and `--git-dir` on its own answers relatively whenever it can.
  local res = M.run({ 'git', 'rev-parse', '--absolute-git-dir' }, cwd)
  return res.ok and vim.trim(res.stdout) or nil
end

--- @param cwd string
--- @return string? dir absolute path of the directory every worktree of the
---         repository shares, which holds the refs and the config
function M.common_dir(cwd)
  -- The same as `M.dir` but in a linked worktree, whose own directory holds
  -- only its HEAD and its index.
  local res = M.run({ 'git', 'rev-parse', '--path-format=absolute', '--git-common-dir' }, cwd)
  return res.ok and vim.trim(res.stdout) or nil
end

--- Whether the repository has a commit yet.
---
--- Before the first commit there is no HEAD to restore from, so the commands
--- that take a file out of the index have to be chosen differently. The
--- condition belongs to the repository rather than to any one file.
---
--- @param cwd string
--- @return boolean
function M.has_head(cwd)
  return M.run({ 'git', 'rev-parse', '--verify', '--quiet', 'HEAD' }, cwd).ok
end

--- Parse the stream `git cat-file --batch` writes.
---
--- Each object is a header line `<sha> <type> <size>` followed by exactly
--- `size` bytes and a newline; a spec that resolves to nothing yields
--- `<spec> missing` instead. Objects come back in the order they were asked
--- for, so results are matched by position rather than by parsing the spec back
--- out of the header.
---
--- @param out string raw stdout, which must not have been newline-converted
--- @return (string[]|false)[]
function M.parse_batch(out)
  local results = {}
  local pos = 1
  while pos <= #out do
    local nl = out:find('\n', pos, true)
    if not nl then
      break
    end
    local header = out:sub(pos, nl - 1)
    local size = header:match('^%x+ %w+ (%d+)$')
    if size then
      local body = out:sub(nl + 1, nl + tonumber(size))
      results[#results + 1] = blob_lines(body)
      pos = nl + 1 + tonumber(size) + 1 -- content, then its trailing newline
    else
      -- `<spec> missing`, or anything else we cannot make sense of
      results[#results + 1] = false
      pos = nl + 1
    end
  end
  return results
end

--- Read many blobs with one `git cat-file` rather than one `git show` each.
--- Spawning a process per file dominates the cost of a large diff.
---
--- @param specs string[] revision specs, e.g. `HEAD:src/init.lua`
--- @param cwd string
--- @return (string[]|false)[] contents per spec, `false` when it does not exist
function M.batch_show(specs, cwd)
  if #specs == 0 then
    return {}
  end
  -- `text = true` would rewrite CRLF and desynchronise the byte counts in the
  -- headers, so the stream is read raw.
  local res = M.run({ 'git', 'cat-file', '--batch' }, cwd, {
    text = false,
    stdin = table.concat(specs, '\n') .. '\n',
  })
  if not res.ok then
    return {}
  end
  return M.parse_batch(res.stdout)
end

--- Parse `git diff --name-status -z`.
---
--- Records are NUL-separated: `M<NUL>path` for ordinary changes and
--- `R100<NUL>old<NUL>new` for renames and copies, where the number is a
--- similarity score.
---
--- @param out string
--- @return gitview.Change[]
function M.parse_name_status(out)
  local fields = vim.split(out, '\0', { plain = true })
  local changes = {}
  local i = 1
  while i <= #fields do
    local status = fields[i]
    if status == '' then
      break
    end
    local letter = status:sub(1, 1)
    if letter == 'R' or letter == 'C' then
      changes[#changes + 1] = {
        status = letter,
        old_path = fields[i + 1],
        path = fields[i + 2],
        binary = false,
      }
      i = i + 3
    else
      changes[#changes + 1] = {
        status = letter,
        old_path = fields[i + 1],
        path = fields[i + 1],
        binary = false,
      }
      i = i + 2
    end
  end
  return changes
end

--- Parse `git diff --numstat -z` and return the paths git considers binary.
---
--- Each record is `added<TAB>deleted<TAB>path`, with `-` for both counts when
--- the file is binary. Renames leave the path field empty and follow it with
--- the old and new paths as separate records.
---
--- @param out string
--- @return table<string, true>
function M.parse_binary(out)
  local fields = vim.split(out, '\0', { plain = true })
  local binary = {}
  local i = 1
  while i <= #fields do
    local rec = fields[i]
    if rec == '' then
      break
    end
    local added, _, path = rec:match('^([^\t]*)\t([^\t]*)\t(.*)$')
    if path == '' then
      -- rename: the real paths are the next two records
      path = fields[i + 2] or fields[i + 1]
      i = i + 3
    else
      i = i + 1
    end
    if added == '-' and path then
      binary[path] = true
    end
  end
  return binary
end

--- Split the NUL-separated path list `-z` produces.
---
--- The stream ends with a separator rather than delimiting between paths, so
--- the final field is empty and is dropped. A path may contain anything but
--- NUL, which is the whole reason for asking for this format.
---
--- @param out string
--- @return string[]
function M.parse_paths(out)
  return vim.split(out, '\0', { plain = true, trimempty = true })
end

--- List a change set, whatever command names it.
---
--- `git diff` and `git diff-tree` print the same `--name-status` and
--- `--numstat` records, so both are read by the same parsers and differ only in
--- how the two sides are named.
---
--- @param prefix string[] the git command, up to but not including the format
--- @param args string[] what to compare, appended after the format flags
--- @param cwd string
--- @param opts? table passed on to `M.run`
--- @return gitview.Change[]? changes
--- @return string? err why the command failed
local function changes_of(prefix, args, cwd, opts)
  local function listing(format)
    local cmd = vim.list_extend({}, prefix)
    vim.list_extend(cmd, { format, '-z', '--find-renames' })
    return M.run(vim.list_extend(cmd, args), cwd, opts)
  end
  local status = listing('--name-status')
  if not status.ok then
    return nil, status.stderr
  end
  local changes = M.parse_name_status(status.stdout)

  -- A failure here only costs the binary flags, so the listing is still useful.
  local numstat = listing('--numstat')
  if numstat.ok then
    local binary = M.parse_binary(numstat.stdout)
    for _, c in ipairs(changes) do
      c.binary = binary[c.path] or false
    end
  end
  return changes
end

--- @param args string[] what to compare, as passed to `git diff`
--- @param cwd string
--- @return gitview.Change[]? changes
--- @return string? err why the command failed
local function diff_changes(args, cwd)
  return changes_of({ 'git', 'diff' }, args, cwd)
end

--- List everything that differs between HEAD and the index.
--- @param cwd string
--- @return gitview.Change[]? changes
--- @return string? err
function M.changed_staged(cwd)
  return diff_changes({ '--cached' }, cwd)
end

--- List everything that differs between the index and the working tree.
--- @param cwd string
--- @return gitview.Change[]? changes
--- @return string? err
function M.changed_unstaged(cwd)
  return diff_changes({}, cwd)
end

--- The file mode the index records for a path, from `git ls-files -s`, whose
--- records are `<mode> <sha> <stage><TAB><path>`.
---
--- `nil` means the index has no entry, which is the case for an untracked file
--- and for a staged deletion. There is then no mode to carry over and the
--- caller has to choose one.
---
--- @param path string repo-relative
--- @param cwd string
--- @return string? mode six octal digits
function M.index_mode(path, cwd)
  local res = M.run({ 'git', 'ls-files', '-s', '--', path }, cwd)
  if not res.ok then
    return nil
  end
  return res.stdout:match('^(%d+) ')
end

--- Write `content` into the object database and return its hash.
---
--- `--path` is what makes git apply the same clean filter it would for a real
--- checkout of that path. Without it a file under a filter would be stored in
--- its working-tree form and the index would disagree with what `git add` does.
---
--- @param path string repo-relative, for the filters it selects
--- @param content string
--- @param cwd string
--- @return string? sha
--- @return string? err
function M.hash_object(path, content, cwd)
  local res = M.run({ 'git', 'hash-object', '-w', '--path', path, '--stdin' }, cwd, {
    stdin = content,
  })
  if not res.ok then
    return nil, res.stderr
  end
  return vim.trim(res.stdout)
end

--- Point the index entry for `path` at an object already in the database.
---
--- `--add` covers a path the index does not hold yet, which is how the first
--- lines of an untracked file get staged.
---
--- @param mode string
--- @param sha string
--- @param path string repo-relative
--- @param cwd string
--- @return string? err
function M.update_index(mode, sha, path, cwd)
  local spec = ('%s,%s,%s'):format(mode, sha, path)
  local res = M.run({ 'git', 'update-index', '--add', '--cacheinfo', spec }, cwd)
  if res.ok then
    return nil
  end
  return res.stderr
end

--- Drop the index entry for `path` without touching the working tree.
---
--- `--force-remove` is the only form that works for a path the working tree
--- still has; plain `--remove` keeps the entry while the file is there.
---
--- @param path string repo-relative
--- @param cwd string
--- @return string? err
function M.remove_index_entry(path, cwd)
  local res = M.run({ 'git', 'update-index', '--force-remove', '--', path }, cwd)
  if res.ok then
    return nil
  end
  return res.stderr
end

--- @class gitview.Commit
--- @field sha string abbreviated
--- @field full_sha string unabbreviated, as other commands than `log` print it
--- @field parents string[] abbreviated; empty for the root commit
--- @field subject string
--- @field author string
--- @field when string relative date, as `%ar` prints it

--- `-z` already spends NUL on separating the records, so the fields within one
--- are separated by a unit separator: a subject can hold anything but a
--- newline, and that includes every other plausible delimiter.
local LOG_FORMAT = '%h%x1f%H%x1f%p%x1f%s%x1f%an%x1f%ar'

--- Parse the stream `git log -z --format=LOG_FORMAT` writes.
---
--- `-z` terminates every record rather than delimiting between them, so the
--- last field is empty and is dropped, as in `parse_paths`. `%p` is a
--- space-separated parent list and is empty for the root commit.
---
--- @param out string
--- @return gitview.Commit[]
function M.parse_log(out)
  local commits = {}
  for _, rec in ipairs(vim.split(out, '\0', { plain = true, trimempty = true })) do
    local f = vim.split(rec, '\31', { plain = true })
    commits[#commits + 1] = {
      sha = f[1],
      full_sha = f[2] or '',
      parents = (f[3] and f[3] ~= '') and vim.split(f[3], ' ', { plain = true }) or {},
      subject = f[4] or '',
      author = f[5] or '',
      when = f[6] or '',
    }
  end
  return commits
end

--- The most recent commits, newest first.
---
--- A repository with no HEAD has no log, and `git log` fails outright there
--- rather than printing nothing, so the caller has to know whether there is a
--- HEAD before asking.
---
--- @param count integer how many to ask for
--- @param cwd string
--- @return gitview.Commit[]? commits
--- @return string? err
function M.log(count, cwd)
  local res = M.run({ 'git', 'log', '-z', '--format=' .. LOG_FORMAT, '-n', tostring(count) }, cwd)
  if not res.ok then
    return nil, res.stderr
  end
  return M.parse_log(res.stdout)
end

--- @class gitview.Upstream the branch the current one tracks
--- @field sha string full; the commit it points at
--- @field ref string full, as `refs/remotes/origin/main`
--- @field name string short, as `origin/main`

--- What the current branch tracks, if anything.
---
--- Nil when there is none: a branch that tracks nothing, a detached HEAD, an
--- upstream that has been deleted. Those are ordinary states rather than
--- failures, so the caller has nothing to report.
---
--- One `rev-parse` answers all three, since each option applies to the
--- arguments after it. `--abbrev-ref` comes last: once given, it is not undone
--- by `--symbolic-full-name`.
---
--- @param cwd string
--- @return gitview.Upstream?
function M.upstream(cwd)
  local res = M.run({
    'git',
    'rev-parse',
    '@{upstream}',
    '--symbolic-full-name',
    '@{upstream}',
    '--abbrev-ref',
    '@{upstream}',
  }, cwd)
  if not res.ok then
    return nil
  end
  local lines = vim.split(vim.trim(res.stdout), '\n', { plain = true })
  return { sha = lines[1], ref = lines[2], name = lines[3] }
end

--- The commits HEAD has and `upstream` does not, as a set of full shas.
---
--- Capped like the log, and listed in the same order, so whichever of the first
--- `count` commits of the log are unpushed are among the first `count` here.
---
--- @param count integer
--- @param upstream string the commit the upstream points at, resolved once with
---        `M.upstream` so that both answers are about the same one
--- @param cwd string
--- @return table<string, true>?
function M.unpushed(count, upstream, cwd)
  local res = M.run({ 'git', 'rev-list', '-n', tostring(count), 'HEAD', '--not', upstream }, cwd)
  if not res.ok then
    return nil
  end
  local set = {}
  for _, sha in ipairs(vim.split(res.stdout, '\n', { plain = true, trimempty = true })) do
    set[sha] = true
  end
  return set
end

--- @class gitview.Range the two revisions a view compares
--- @field old string? nil when the new side has no parent, i.e. a root commit
--- @field new string? nil for the working tree. The two are never both nil: a
---        range ending at the working tree starts at a commit

--- The range one commit stands for: its first parent to itself.
---
--- A merge is compared with its first parent only, which is what `git show`
--- does. `git diff-tree -m` would instead concatenate one diff per parent, and
--- `--no-commit-id` removes the headers that would tell the blocks apart;
--- `--first-parent` is a rev-list option that `diff-tree` rejects. Naming the
--- parent explicitly avoids the question, and keeps the decision here rather
--- than in everything that reads a range.
---
--- @param commit gitview.Commit
--- @return gitview.Range
function M.commit_range(commit)
  return { old = commit.parents[1], new = commit.sha }
end

--- The command that compares the two sides of a range, before its options.
--- Both print the same records for the same options, so whatever is asked of a
--- range is asked the same way of a root commit.
---
--- @param range gitview.Range
--- @return string[]
local function range_command(range)
  if not range.old then
    return { 'git', 'diff-tree', '--no-commit-id', '-r', '--root' }
  end
  return { 'git', 'diff' }
end

--- What `range_command` compares, after its options. `git diff` given one
--- revision compares it with the working tree, which is how a range ends there.
--- @param range gitview.Range
--- @return string[]
local function range_args(range)
  if not range.old then
    local new = assert(range.new, 'a range starting nowhere must end at a commit')
    return { new }
  end
  return { range.old, range.new }
end

--- What changed between a commit and the working tree, untracked files
--- included.
---
--- `git diff <rev>` only compares the paths the index names, so an untracked
--- file would be left out. It is put in a copy of the index as an intent to add
--- (`git add -N`), which names the path without taking its contents, and the diff
--- is run against that copy through `GIT_INDEX_FILE`. git then treats the file as
--- any other: an addition, a modification of a path the old side had, or one end
--- of a rename. The real index is never written, so nothing the user staged moves.
---
--- The copy is taken rather than started empty because the diff lists the paths
--- the index names; an empty one would report every tracked file as deleted.
---
--- @param old string
--- @param untracked string[]
--- @param cwd string
--- @return gitview.Change[]? changes
--- @return string? err
local function changed_since(old, untracked, cwd)
  if #untracked == 0 then
    return changes_of({ 'git', 'diff' }, { old }, cwd)
  end
  local dir = M.dir(cwd)
  if not dir then
    return nil, 'the git directory could not be found'
  end
  local index = vim.fn.tempname()
  -- git replaces the index by renaming a finished one over it, so a copy is of
  -- one whole version or another, never of a write under way.
  local copied, copy_err = vim.uv.fs_copyfile(vim.fs.joinpath(dir, 'index'), index)
  if not copied then
    return nil, 'could not copy the index: ' .. tostring(copy_err)
  end
  local opts = { env = { GIT_INDEX_FILE = index } }
  -- The paths go in on stdin, since a working tree can hold more of them than a
  -- command line does.
  local added = M.run(
    { 'git', 'add', '--intent-to-add', '--pathspec-from-file=-', '--pathspec-file-nul' },
    cwd,
    vim.tbl_extend('force', opts, { stdin = table.concat(untracked, '\0') })
  )
  local changes, err
  if added.ok then
    changes, err = changes_of({ 'git', 'diff' }, { old }, cwd, opts)
  else
    err = added.stderr
  end
  os.remove(index)
  return changes, err
end

--- What changed between the two sides of a range.
---
--- A root commit has no old side to name, and is the one case that needs
--- `diff-tree --root`. Every other range, including one whose ends are merges,
--- is an ordinary comparison of two trees, or of a tree and the working tree.
---
--- @param range gitview.Range
--- @param cwd string
--- @param untracked string[]? for a range ending at the working tree, the files
---        git is not tracking, when the caller has already listed them. Read
---        here otherwise, which walks the whole working tree
--- @return gitview.Change[]? changes
--- @return string? err
function M.changed_between(range, cwd, untracked)
  if range.new or not range.old then
    return changes_of(range_command(range), range_args(range), cwd)
  end
  if not untracked then
    local err
    untracked, err = M.untracked(cwd)
    if not untracked then
      return nil, err
    end
  end
  return changed_since(range.old, untracked, cwd)
end

--- @class gitview.CommitDetail what a commit says beyond its row in the log
--- @field author string name and email
--- @field date string the author date, as `git show` prints it
--- @field message string[] the subject, then the body as it was written
--- @field stat string[] `--stat` of the commit's range: a row per file, then a
---        summary
--- @field stat_width integer the columns the stat was laid out to fill

--- Read the whole message of a commit and the stat of its range.
---
--- The stat is git's own rather than one counted from the view: it covers the
--- binary files and the renames the view leaves out, and it describes the
--- commit rather than how the view happens to be drawn, so ignoring whitespace
--- does not change it.
---
--- Git shortens a path that does not fit the stat's width from its start, and
--- without a terminal to measure it takes the width to be 80 columns.
---
--- @param commit gitview.Commit
--- @param cwd string
--- @param width integer columns the stat may take
--- @return gitview.CommitDetail? detail
--- @return gitview.GitError? err
function M.commit_detail(commit, cwd, width)
  -- `log.showSignature` would put the signature check in front of the format.
  local log = M.run({
    'git',
    'log',
    '-1',
    '--no-show-signature',
    '--format=%an <%ae>%x1f%ad%x1f%B',
    commit.sha,
  }, cwd)
  if not log.ok then
    return nil, { what = 'git log ' .. commit.sha, stderr = log.stderr }
  end
  local f = vim.split(log.stdout, '\31', { plain = true })

  local range = M.commit_range(commit)
  local cmd = range_command(range)
  -- `color.ui = always` colors output that is not going to a terminal as well.
  -- The graph would otherwise take up to 40 columns, which is a lot of `+` to
  -- read past above the diff that shows the same lines.
  vim.list_extend(cmd, { '--stat=' .. width, '--stat-graph-width=30', '--no-color', '--find-renames' })
  local stat = M.run(vim.list_extend(cmd, range_args(range)), cwd)
  if not stat.ok then
    return nil, { what = 'git diff --stat ' .. commit.sha, stderr = stat.stderr }
  end

  return {
    author = f[1] or '',
    date = f[2] or '',
    message = vim.split((f[3] or ''):gsub('%s+$', ''), '\n', { plain = true }),
    stat = vim.split(stat.stdout:gsub('\n$', ''), '\n', { plain = true, trimempty = true }),
    stat_width = width,
  }
end

--- Whether `a` is an ancestor of `b`.
---
--- This is what tells a range that spans one line of history from one whose ends
--- sit on branches that diverged. `git diff` compares the two trees either way,
--- but only in the first case does the result read as "what happened between
--- these two commits": across a fork it also undoes whatever the other side did.
---
--- @param a string
--- @param b string
--- @param cwd string
--- @return boolean
function M.is_ancestor(a, b, cwd)
  return M.run({ 'git', 'merge-base', '--is-ancestor', a, b }, cwd).ok
end

--- The tree with nothing in it, for a range to start from when the commit it
--- starts at has no parent.
---
--- Asked of the repository rather than written down: its name depends on the
--- object format, and differs between a SHA-1 and a SHA-256 repository. Writing
--- it is not needed either, since git knows the empty tree without storing it.
---
--- @param cwd string
--- @return string? sha
function M.empty_tree(cwd)
  local res = M.run({ 'git', 'hash-object', '-t', 'tree', '--stdin' }, cwd, { stdin = '' })
  if not res.ok then
    return nil
  end
  return vim.trim(res.stdout)
end

--- Files git is not tracking and has not been told to ignore.
---
--- `git diff` never reports these, so they are the one part of the working tree
--- that has to be asked for separately.
---
--- @param cwd string the repository root; paths come back relative to it
--- @return string[]? paths
--- @return string? err
function M.untracked(cwd)
  local res = M.run({ 'git', 'ls-files', '--others', '--exclude-standard', '-z' }, cwd)
  if not res.ok then
    return nil, res.stderr
  end
  return M.parse_paths(res.stdout)
end

return M
