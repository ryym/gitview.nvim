--- `make bench`: time every scenario in `bench/scenarios.lua`, and compare the
--- result with the runs before it.
---
---   nvim --headless --clean -l bench/run.lua [scenario...]
---
--- Each sample runs in a Neovim of its own (`bench/sample.lua`), so that none
--- inherits another's caches, buffers or garbage. The repository of a scenario
--- is built once and shared by its samples.
---
--- Runs are appended to `.local/bench/history.jsonl`, which is never committed:
--- the numbers belong to the machine they were taken on. The report compares
--- each median with the median of the last few runs on the same machine and
--- Neovim, and nothing fails on a slowdown; the numbers vary too much from run
--- to run to decide that.
---
--- Environment:
---   BENCH_N    samples per scenario, 3 by default
---   BENCH_RTP  extra runtimepath entries, comma-separated, such as a parser
---              directory a scenario `requires`
local root = assert(vim.uv.cwd())
local helpers = dofile(root .. '/tests/helpers.lua')
local scenarios = dofile(root .. '/bench/scenarios.lua')

local N = tonumber(vim.env.BENCH_N) or 3
local HISTORY = root .. '/.local/bench/history.jsonl'
--- How many earlier runs a median is compared against.
local BASELINE_RUNS = 5
--- How much slower than the baseline a median has to be to be flagged.
local FLAG_RATIO = 1.2

local rtp = { root }
for dir in (vim.env.BENCH_RTP or ''):gmatch('[^,]+') do
  rtp[#rtp + 1] = vim.fs.normalize(dir)
end

--- @param ...string
--- @return string
local function git_here(...)
  local out = vim.system({ 'git', ... }, { cwd = root, text = true }):wait()
  return vim.trim(out.stdout or '')
end

--- @param xs number[]
--- @return number
local function median(xs)
  local t = vim.deepcopy(xs)
  table.sort(t)
  local n = #t
  return n % 2 == 1 and t[(n + 1) / 2] or (t[n / 2] + t[n / 2 + 1]) / 2
end

--- Run one sample of `sc` against `repo_root`.
--- @param sc gitview.BenchScenario
--- @param repo_root string
--- @return table result as `bench/sample.lua` reports it
local function sample(sc, repo_root)
  local out = vim
    .system({
      vim.v.progpath,
      '--headless',
      '--clean',
      '--cmd',
      'set rtp+=' .. table.concat(rtp, ','),
      '-c',
      'luafile ' .. root .. '/bench/sample.lua',
    }, {
      text = true,
      env = { BENCH_ROOT = root, BENCH_SCENARIO = sc.name, BENCH_REPO = repo_root },
      timeout = 120000,
    })
    :wait()
  for line in (out.stdout or ''):gmatch('[^\n]+') do
    local json = line:match('^BENCH (.*)$')
    if json then
      return vim.json.decode(json)
    end
  end
  return { error = ('exit %s: %s%s'):format(out.code, out.stdout or '', out.stderr or '') }
end

--- @param sc gitview.BenchScenario
--- @return table entry the scenario's line of the run
local function run_scenario(sc)
  io.write(('%-22s'):format(sc.name))
  io.flush()
  local entry
  helpers.with_repo(function(repo)
    sc.setup(repo)
    local samples = {} --- @type table<string, number[]>
    for _ = 1, N do
      local r = sample(sc, repo.root)
      if r.error or r.skipped then
        entry = { error = r.error, skipped = r.skipped }
        return
      end
      if sc.path and r.path ~= sc.path then
        entry = entry or {}
        entry.warning = ('%s was highlighted through %s, not %s'):format(sc.lang, r.path, sc.path)
      end
      for k, v in pairs(r.metrics) do
        samples[k] = samples[k] or {}
        table.insert(samples[k], v)
      end
      io.write('.')
      io.flush()
    end
    entry = entry or {}
    entry.metrics = {}
    for k, vs in pairs(samples) do
      entry.metrics[k] = median(vs)
    end
  end)
  io.write('\n')
  return entry
end

--- The earlier runs taken where this one is.
--- @param env table
--- @return table[]
local function earlier_runs(env)
  local runs = {}
  if vim.fn.filereadable(HISTORY) == 0 then
    return runs
  end
  for _, line in ipairs(vim.fn.readfile(HISTORY)) do
    local ok, run = pcall(vim.json.decode, line)
    if ok and run.host == env.host and run.nvim == env.nvim then
      runs[#runs + 1] = run
    end
  end
  return { unpack(runs, math.max(1, #runs - BASELINE_RUNS + 1)) }
end

--- The median of what earlier runs measured for one metric, if any did.
--- @param runs table[]
--- @param name string
--- @param metric string
--- @return number?
local function baseline(runs, name, metric)
  local vs = {}
  for _, run in ipairs(runs) do
    local e = run.scenarios[name]
    local v = e and e.metrics and e.metrics[metric]
    if v then
      vs[#vs + 1] = v
    end
  end
  return #vs > 0 and median(vs) or nil
end

--- @param run table
--- @param runs table[] earlier runs to compare with
local function report(run, runs)
  io.write(
    ('\n%s%s, Neovim %s, %d samples each\n'):format(
      run.sha,
      run.dirty and ' (dirty)' or '',
      run.nvim,
      N
    )
  )
  io.write(('compared with the last %d runs on this machine\n\n'):format(#runs))
  io.write(('%-22s %-9s %10s %10s %8s\n'):format('scenario', 'metric', 'median', 'baseline', 'change'))
  local flagged = 0
  for _, sc in ipairs(scenarios.list) do
    local e = run.scenarios[sc.name]
    if e then
      if e.skipped then
        io.write(('%-22s skipped: %s\n'):format(sc.name, e.skipped))
      elseif e.error then
        io.write(('%-22s ERROR\n%s\n'):format(sc.name, e.error))
      else
        local metrics = vim.tbl_keys(e.metrics)
        table.sort(metrics)
        for i, m in ipairs(metrics) do
          local v, b = e.metrics[m], baseline(runs, sc.name, m)
          local change, mark = '', ''
          if b and b > 0 then
            change = ('%+.0f%%'):format((v / b - 1) * 100)
            if v / b >= FLAG_RATIO then
              mark, flagged = '  !', flagged + 1
            end
          end
          io.write(
            ('%-22s %-9s %10.1f %10s %8s%s\n'):format(
              i == 1 and sc.name or '',
              m,
              v,
              b and ('%.1f'):format(b) or '-',
              change,
              mark
            )
          )
        end
        if e.warning then
          io.write(('%-22s warning: %s\n'):format('', e.warning))
        end
      end
    end
  end

  io.write('\nscaling (a ratio near the size factor is linear, near its square quadratic)\n')
  for _, pair in ipairs(scenarios.scaling) do
    local s, l = run.scenarios[pair.small], run.scenarios[pair.large]
    if s and l and s.metrics and l.metrics then
      io.write(
        ('  %s / %s (x%d): full %.1f\n'):format(
          pair.large,
          pair.small,
          pair.factor,
          l.metrics.full_ms / s.metrics.full_ms
        )
      )
    end
  end
  if flagged > 0 then
    io.write(
      ('\n%d metrics are %.0f%% or more over their baseline (!)\n'):format(
        flagged,
        (FLAG_RATIO - 1) * 100
      )
    )
  end
end

local names = _G.arg and #_G.arg > 0 and _G.arg or nil
local selected = {} --- @type gitview.BenchScenario[]
for _, sc in ipairs(scenarios.list) do
  if not names or vim.tbl_contains(names, sc.name) then
    selected[#selected + 1] = sc
  end
end
for _, name in ipairs(names or {}) do
  assert(scenarios.by_name[name], 'no such scenario: ' .. name)
end

local run = {
  time = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  sha = git_here('rev-parse', '--short', 'HEAD'),
  dirty = git_here('status', '--porcelain', '--untracked-files=no') ~= '',
  host = vim.uv.os_gethostname(),
  nvim = tostring(vim.version()),
  samples = N,
  scenarios = {},
}
local runs = earlier_runs(run)
local t0 = vim.uv.hrtime()
for _, sc in ipairs(selected) do
  run.scenarios[sc.name] = run_scenario(sc)
end
io.write(('\ntook %.0f s\n'):format((vim.uv.hrtime() - t0) / 1e9))

report(run, runs)

vim.fn.mkdir(vim.fs.dirname(HISTORY), 'p')
local f = assert(io.open(HISTORY, 'a'))
f:write(vim.json.encode(run) .. '\n')
f:close()
