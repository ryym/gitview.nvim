--- One sample of one scenario, run by `bench/run.lua` in a Neovim of its own:
---
---   nvim --headless --clean --cmd 'set rtp+=<root>' -c 'luafile bench/sample.lua'
---
--- It is sourced with `-c` rather than run with `-l` so that the main loop is
--- the one a user has: keys typed are what moves the cursor, `CursorMoved`
--- fires from them, and the screen is redrawn when Neovim would redraw it. The
--- scenario is driven from a coroutine resumed by timers, which lets the loop
--- run in between.
---
--- What it reads from the plugin is the timing log's spans (see `perf.lua`),
--- and only to know when the work it started is over: a step is done once
--- no span is open and the loop has stayed quiet for a moment. Which spans
--- there are does not matter, except that `select` is the one a selection is
--- timed by. When a redraw is over is told by a decoration provider.
---
--- The result is written to stdout as one line, `BENCH <json>`.
local perf = require('gitview.perf')
local scenarios = dofile(vim.env.BENCH_ROOT .. '/bench/scenarios.lua')

local scenario = assert(scenarios.by_name[vim.env.BENCH_SCENARIO], 'no such scenario')

--- @param result table
local function report(result)
  io.stdout:write('BENCH ' .. vim.json.encode(result) .. '\n')
end

local open_spans = 0
--- When the last span started and finished, and when the last redraw did.
local last_start, last_finish, last_redraw = 0, 0, 0
--- When a selection's span finished, and when the last span inside it started.
local select_finish, select_last_start = 0, 0
--- When each redraw since the current step began ended.
local redraws = {} --- @type number[]

-- Spans are handed out only while logging is on; the lines go nowhere useful.
vim.g.gitview_perf = 1
perf.file = vim.fn.tempname()
local start = perf.start
perf.start = function(name, fields)
  local span = start(name, fields)
  open_spans = open_spans + 1
  local started = vim.uv.hrtime()
  -- The select span is the outer one; what its view took is inside it.
  if name ~= 'select' then
    last_start = started
  end
  local done = false
  return {
    finish = function(_, more)
      if not done then
        done = true
        open_spans = open_spans - 1
        last_finish = vim.uv.hrtime()
        if name == 'select' then
          select_finish = last_finish
          select_last_start = math.max(last_start, started)
        end
      end
      span:finish(more)
    end,
  }
end

-- `on_end` is called once a redraw is over, which is when what was drawn is on
-- screen.
vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace('gitview.bench'), {
  on_end = function()
    last_redraw = vim.uv.hrtime()
    redraws[#redraws + 1] = last_redraw
  end,
})

local co

--- Let the main loop run for `ms`, then come back.
--- @param ms integer
local function sleep(ms)
  vim.defer_fn(function()
    local ok, err = coroutine.resume(co)
    if not ok then
      report({ error = debug.traceback(co, err) })
      vim.cmd('cquit 1')
    end
  end, ms)
  coroutine.yield()
end

local TIMEOUT_NS = 60 * 1e9

--- @param cond fun(): boolean
--- @param what string
local function wait_for(cond, what)
  local deadline = vim.uv.hrtime() + TIMEOUT_NS
  while not cond() do
    if vim.uv.hrtime() > deadline then
      error('timed out waiting for ' .. what)
    end
    sleep(1)
  end
end

--- How long the loop has to stay quiet, with no span open, for the work to be
--- over. Neovim redraws as soon as it has nothing else to do, so a redraw still
--- owed would happen within it.
local QUIET_MS = 20

--- Wait until everything started since `t0` is over and on screen, and return
--- when that was: the later of the last span finishing and the last redraw.
--- The last span may well redraw by itself before it finishes, and leave
--- nothing for Neovim to redraw after it.
--- @param t0 number
--- @return number
local function settle(t0)
  wait_for(function()
    return last_redraw > t0
  end, 'a redraw')
  while true do
    wait_for(function()
      return open_spans == 0
    end, 'the work to finish')
    local done = math.max(last_finish, last_redraw)
    sleep(QUIET_MS)
    if open_spans == 0 and math.max(last_finish, last_redraw) == done then
      return done
    end
  end
end

--- When the view a selection drew reached the screen.
---
--- Either Neovim redraws once the selection is over, or the plugin redraws by
--- itself before it is over, as a view whose colors come later does. The
--- latter is told apart by a redraw after the last span inside the selection
--- started: one before it is of something else, such as a placeholder shown
--- while the view was read.
--- @return number
local function shown_at()
  local inside, after
  for _, r in ipairs(redraws) do
    if r > select_last_start and r <= select_finish then
      inside = r
    elseif r > select_finish and not after then
      after = r
    end
  end
  return inside or after or select_finish
end

--- @class gitview.BenchTiming
--- @field shown number? ms until the screen showed the selection's view
--- @field full number ms until nothing was left to do, and that was on screen

--- @class gitview.BenchContext
--- @field keys fun(keys: string): gitview.BenchTiming type keys and wait
--- @field select fun(text: string): gitview.BenchTiming move the cursor onto
---        the row of the current pane holding `text`
--- @field focus fun(pane: 'files'|'commits'|'diff') go to a pane

--- @type gitview.BenchContext
local ctx = {}

function ctx.keys(keys)
  local t0 = vim.uv.hrtime()
  select_finish, redraws = 0, {}
  -- Not remapped, so that a mapping can only come from the plugin, and typed,
  -- as if from the keyboard.
  vim.api.nvim_feedkeys(vim.keycode(keys), 'nt', false)
  local done = settle(t0)
  local function since(t)
    return (t - t0) / 1e6
  end
  return {
    shown = select_finish > 0 and since(shown_at()) or nil,
    full = since(done),
  }
end

--- The panes by their buffer names, which is how they are told apart from
--- outside. Which pane a session starts in depends on whether there is
--- anything uncommitted.
local PANES = { Gitview = 'files', ['Gitview:commits'] = 'commits', ['Gitview:diff'] = 'diff' }

--- The keys from one pane to another. Each goes straight there: passing
--- through a list on the way would select its row and replace the diff.
local MOVES = {
  files = { commits = '<C-w>j', diff = '<C-w>l' },
  commits = { files = '<C-w>k', diff = '<C-w>l' },
}

function ctx.focus(pane)
  local here = PANES[vim.fn.bufname()]
  if here == pane then
    return
  end
  local keys = assert(MOVES[here] and MOVES[here][pane], ('no way from %s to %s'):format(here, pane))
  ctx.keys(keys)
  assert(PANES[vim.fn.bufname()] == pane, ('%s did not reach %s'):format(keys, pane))
end

function ctx.select(text)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for row, line in ipairs(lines) do
    if line:find(text, 1, true) then
      local t = ctx.keys(row .. 'G')
      assert(t.shown, ('selecting %q drew nothing'):format(text))
      return t
    end
  end
  error(('no row holds %q: %s'):format(text, vim.inspect(lines)))
end

--- Which way `lang` is highlighted here: a parser, or the syntax file.
--- @param lang string
--- @return 'treesitter'|'syntax'
local function path_of(lang)
  -- `add` reports a missing parser by returning nil, not by erroring.
  local ok, added = pcall(vim.treesitter.language.add, lang)
  return ok and added and 'treesitter' or 'syntax'
end

co = coroutine.create(function()
  if scenario.requires and path_of(scenario.requires) ~= 'treesitter' then
    report({ skipped = ('no %s parser'):format(scenario.requires) })
    vim.cmd('qa!')
    return
  end
  -- Not opened while Neovim is still starting up, which `-c` runs in: a session
  -- opened then ends up with its files pane split in two.
  sleep(0)
  -- A screen of a fixed size, since how much of a view is drawn depends on it.
  vim.o.columns, vim.o.lines = 200, 50
  vim.cmd.lcd(vim.env.BENCH_REPO)
  local t0 = vim.uv.hrtime()
  vim.cmd('Gitview')
  settle(t0)
  -- The status is read in steps; wait for the list to stop changing.
  sleep(100)
  settle(t0)
  local metrics = scenario.measure(ctx)
  report({ metrics = metrics, path = scenario.lang and path_of(scenario.lang) })
  vim.cmd('qa!')
end)
local ok, err = coroutine.resume(co)
if not ok then
  report({ error = debug.traceback(co, err) })
  vim.cmd('cquit 1')
end
