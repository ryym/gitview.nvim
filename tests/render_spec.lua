local dlib = require('unidiff.diff')
local hl = require('unidiff.highlight')
local render = require('unidiff.render')

local test, eq = _G.test, _G.eq

local OLD = {
  'local M = {}',
  '',
  'local doc = [[',
  'plain prose',
  ']]',
  '',
  'function M.add(a, b)',
  '  return a + b',
  'end',
  '',
  'return M',
}
local NEW = {
  'local M = {}',
  '',
  'local doc = [[',
  'plain and tidy prose',
  ']]',
  '',
  'function M.add(a, b, c)',
  '  return a + b',
  'end',
  '',
  'return M',
}

--- @return integer bufnr, unidiff.View
local function build()
  local hunks = dlib.hunks(OLD, NEW)
  local lines, hunk_rows = dlib.build(hunks, OLD, NEW, 3)
  for _, l in ipairs(lines) do
    if dlib.source_kinds[l.kind] then
      l.file = 1
    end
  end
  local old_buf = hl.ghost_buffer(OLD, 'lua')
  local new_buf = hl.ghost_buffer(NEW, 'lua')
  local view = {
    lines = lines,
    hunk_rows = hunk_rows,
    rev = 'HEAD',
    files = {
      {
        path = '/tmp/x.lua',
        label = 'x.lua',
        old_buf = old_buf,
        new_buf = new_buf,
        lang = 'lua',
        row = 1,
      },
    },
  }
  local buf = render.render(view)
  vim.api.nvim_buf_delete(old_buf, { force = true })
  vim.api.nvim_buf_delete(new_buf, { force = true })
  return buf, view
end

local function marks(buf, ns_name, row)
  local ns = vim.api.nvim_get_namespaces()[ns_name]
  return vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true })
end

test('every line of the view is written into the buffer verbatim', function()
  local buf, view = build()
  local text = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(#view.lines, #text)
  for i, l in ipairs(view.lines) do
    eq(l.text, text[i], 'row ' .. i)
  end
  eq(false, vim.bo[buf].modifiable)
end)

test('a deleted line inside a long string is still highlighted as a string', function()
  -- The whole point of the ghost buffers: this line means nothing on its own,
  -- only the surrounding `[[ ]]` makes it a string.
  local buf, view = build()
  local row
  for i, l in ipairs(view.lines) do
    if l.kind == 'del' and l.text:find('plain prose') then
      row = i - 1
    end
  end
  assert(row, 'expected a deleted line inside the long string')
  local groups = {}
  for _, m in ipairs(marks(buf, 'unidiff.syntax', row)) do
    groups[#groups + 1] = m[4].hl_group
  end
  assert(
    vim.tbl_contains(groups, '@string.lua'),
    'expected @string.lua, got ' .. vim.inspect(groups)
  )
end)

test('diff background is a range mark, not line_hl_group', function()
  -- line_hl_group is painted outside extmark priority order and would hide the
  -- word-level highlights entirely.
  local buf, view = build()
  local row
  for i, l in ipairs(view.lines) do
    if l.kind == 'add' then
      row = i - 1
      break
    end
  end
  local found
  for _, m in ipairs(marks(buf, 'unidiff.diff', row)) do
    if m[4].hl_group == 'UnidiffAdd' then
      found = m[4]
    end
    eq(nil, m[4].line_hl_group, 'line_hl_group must not be used')
  end
  assert(found, 'no UnidiffAdd range mark')
  eq(true, found.hl_eol)
  eq(row + 1, found.end_row)
end)

test('word-level marks outrank the line background', function()
  local buf, view = build()
  local line_prio, word_prio
  for i, l in ipairs(view.lines) do
    if l.kind == 'add' and l.text:find('a, b, c') then
      for _, m in ipairs(marks(buf, 'unidiff.diff', i - 1)) do
        if m[4].hl_group == 'UnidiffAdd' then
          line_prio = m[4].priority
        elseif m[4].hl_group == 'UnidiffAddText' then
          word_prio = m[4].priority
        end
      end
    end
  end
  assert(line_prio and word_prio, 'expected both a line and a word mark')
  assert(word_prio > line_prio, 'word mark must win')
end)

test('syntax marks sit above the line background and below the word marks', function()
  local buf, view = build()
  local syn, line_prio, word_prio
  for i, l in ipairs(view.lines) do
    if l.kind == 'add' and l.text:find('a, b, c') then
      syn = marks(buf, 'unidiff.syntax', i - 1)[1][4].priority
      for _, m in ipairs(marks(buf, 'unidiff.diff', i - 1)) do
        if m[4].hl_group == 'UnidiffAdd' then
          line_prio = m[4].priority
        elseif m[4].hl_group == 'UnidiffAddText' then
          word_prio = m[4].priority
        end
      end
    end
  end
  assert(line_prio < syn, 'syntax must beat the line background')
  assert(syn < word_prio, 'word marks must beat syntax')
end)

test('highlight ranges never exceed the line they are on', function()
  local buf, view = build()
  for i, l in ipairs(view.lines) do
    for _, m in ipairs(marks(buf, 'unidiff.syntax', i - 1)) do
      assert(m[4].end_col <= #l.text, ('row %d: end_col %d > %d'):format(i, m[4].end_col, #l.text))
    end
  end
end)

test('the view is dropped when the buffer goes away', function()
  local buf = build()
  assert(render.views[buf], 'view should be registered')
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(nil, render.views[buf])
end)

test('the gutter is numbered for source lines and blank for the rest', function()
  local buf, view = build()
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    width = 40,
    height = 10,
    row = 1,
    col = 1,
  })
  render.configure_window(win, buf)
  vim.g.statusline_winid = win

  vim.v.lnum = 1
  local real = render.statuscolumn()
  assert(real:find('%d'), 'real line should show numbers, got ' .. vim.inspect(real))

  local gap_row
  for i, l in ipairs(view.lines) do
    if l.kind == 'gap' then
      gap_row = i
    end
  end
  assert(gap_row, 'expected the fixture to skip a range')
  vim.v.lnum = gap_row
  local gap = render.statuscolumn()
  eq(nil, gap:find('%d'), 'a gap line has no line numbers')
  -- the highlight-group markers take no width on screen
  eq(#(real:gsub('%%#%S-#', '')), #gap, 'and keeps the gutter the same width')

  vim.api.nvim_win_close(win, true)
  eq(#view.lines, #vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end)

test('separator lines are real lines, not virtual ones', function()
  local buf, view = build()
  local ns = vim.api.nvim_get_namespaces()['unidiff.diff']
  local gap_row
  for i, l in ipairs(view.lines) do
    if l.kind == 'gap' then
      gap_row = i
    end
  end
  assert(gap_row, 'expected the fixture to skip a range')
  eq(
    { view.lines[gap_row].text },
    vim.api.nvim_buf_get_lines(buf, gap_row - 1, gap_row, false)
  )

  local found
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    eq(nil, m[4].virt_lines, 'no virtual lines are left')
    if m[2] == gap_row - 1 and m[4].hl_group == 'UnidiffSeparator' then
      found = m[4]
    end
  end
  assert(found, 'the gap line should carry the separator highlight')
  eq(true, found.hl_eol)
end)

-- The groups whose colors we compute; the rest are plain `default link`s, which
-- survive a colorscheme change on their own.
local COLOR_GROUPS =
  { 'UnidiffAdd', 'UnidiffDelete', 'UnidiffAddText', 'UnidiffDeleteText' }

test('colors are defined by rendering, not by setup()', function()
  -- Reproduce a session where setup() was never called: drop the ColorScheme
  -- hook, then load a colorscheme, which clears every highlight group. Only
  -- opening a diff should be needed to get the colors back.
  vim.api.nvim_create_augroup('unidiff.highlights', { clear = true })
  render.ensure_highlights_reset()
  vim.cmd.colorscheme('default')
  for _, name in ipairs(COLOR_GROUPS) do
    eq({}, vim.api.nvim_get_hl(0, { name = name }), name .. ' should start undefined')
  end

  build()

  for _, name in ipairs(COLOR_GROUPS) do
    local h = vim.api.nvim_get_hl(0, { id = vim.api.nvim_get_hl_id_by_name(name), link = false })
    assert(h.bg, name .. ' should carry a background color')
  end
  for _, name in ipairs({ 'UnidiffSeparator', 'UnidiffFileHeader' }) do
    assert(next(vim.api.nvim_get_hl(0, { name = name })), name .. ' should be defined')
  end
end)

test('add and delete backgrounds differ, and each differs from its word color', function()
  render.setup_highlights()
  local function bg(name)
    return vim.api.nvim_get_hl(0, { id = vim.api.nvim_get_hl_id_by_name(name), link = false }).bg
  end
  assert(bg('UnidiffAdd') ~= bg('UnidiffDelete'), 'add and delete must be distinguishable')
  assert(bg('UnidiffAdd') ~= bg('UnidiffAddText'), 'word highlight must stand out')
  assert(bg('UnidiffDelete') ~= bg('UnidiffDeleteText'), 'word highlight must stand out')
end)

test('a colorscheme change puts the groups back', function()
  render.setup_highlights()
  vim.cmd.colorscheme('default')
  local after = vim.api.nvim_get_hl(0, {
    id = vim.api.nvim_get_hl_id_by_name('UnidiffAdd'),
    link = false,
  })
  assert(after.bg, 'UnidiffAdd should be redefined after :colorscheme')
  eq(
    vim.api.nvim_get_hl(0, { id = vim.api.nvim_get_hl_id_by_name('DiffAdd'), link = false }).bg,
    after.bg,
    'and should follow the new DiffAdd'
  )
end)
