local dlib = require('gitview.diff.lines')
local hl = require('gitview.diff.highlight')
local render = require('gitview.diff.render')

local test, eq = _G.test, _G.eq

--- Assemble a view the way init.build_view does, so the concatenation rules are
--- exercised without needing a git repository.
--- @param sources {label:string, lang:string, old:string[], new:string[]}[]
--- @return integer bufnr, gitview.View
local function build(sources)
  local lines, files, hunk_rows = {}, {}, {}
  for _, src in ipairs(sources) do
    local hunks = dlib.hunks(src.old, src.new)
    local flines, fhunks = dlib.build(hunks, src.old, src.new, 3)
    if #lines > 0 then
      lines[#lines + 1] = { text = '', kind = 'blank' }
    end
    lines[#lines + 1] = { text = src.label, kind = 'file' }
    local offset = #lines
    files[#files + 1] = {
      path = '/tmp/' .. src.label,
      label = src.label,
      old_buf = hl.ghost_buffer(src.old, src.lang),
      new_buf = hl.ghost_buffer(src.new, src.lang),
      lang = src.lang,
      row = offset,
    }
    for _, l in ipairs(flines) do
      l.file = #files
      lines[#lines + 1] = l
    end
    for _, r in ipairs(fhunks) do
      hunk_rows[#hunk_rows + 1] = r + offset
    end
  end
  local view = { lines = lines, files = files, hunk_rows = hunk_rows, rev = 'HEAD' }
  local buf = render.render(view)
  return buf, view
end

local LUA = {
  label = 'a.lua',
  lang = 'lua',
  old = { 'local x = 1', 'return x' },
  new = { 'local x = 2', 'return x' },
}
local PERL = {
  label = 'b.pl',
  lang = 'perl',
  old = { 'my $y = 1;', 'print $y;' },
  new = { 'my $y = 2;', 'print $y;' },
}

test('files are laid out one after another', function()
  local buf, view = build({ LUA, PERL })
  eq(2, #view.files)
  -- header, del, add, context, then a blank and the second header
  eq(1, view.files[1].row)
  eq(6, view.files[2].row)
  eq('file', view.lines[view.files[2].row].kind)
  eq(2, view.lines[view.files[2].row + 1].file)
  eq(#view.lines, #vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end)

test('every line is written into the buffer verbatim', function()
  local buf, view = build({ LUA, PERL })
  local text = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(view.lines) do
    eq(l.text, text[i], 'row ' .. i)
  end
end)

test('each file is highlighted with its own language', function()
  vim.cmd('syntax enable')
  local buf, view = build({ LUA, PERL })
  local ns = vim.api.nvim_get_namespaces()['gitview.syntax']
  local by_file = { {}, {} }
  for i, l in ipairs(view.lines) do
    for _, m in ipairs(
      vim.api.nvim_buf_get_extmarks(buf, ns, { i - 1, 0 }, { i - 1, -1 }, { details = true })
    ) do
      by_file[l.file][m[4].hl_group] = true
    end
  end
  assert(next(by_file[1]), 'lua file has no highlights')
  assert(next(by_file[2]), 'perl file has no highlights')
  for group in pairs(by_file[1]) do
    assert(group:match('%.lua$'), 'expected a lua group, got ' .. group)
  end
  for group in pairs(by_file[2]) do
    assert(group:match('^perl'), 'expected a perl group, got ' .. group)
  end
end)

test('hunk rows are offset into the combined buffer', function()
  local _, view = build({ LUA, PERL })
  -- a.lua renders as del, add and one context line under its header
  eq({ 2, 7 }, view.hunk_rows)
end)

test('file headers are ordinary lines, one per file', function()
  local buf, view = build({ LUA, PERL })
  local headers = {}
  for i, l in ipairs(view.lines) do
    if l.kind == 'file' then
      headers[#headers + 1] = { row = i, text = l.text }
    end
  end
  eq(2, #headers, 'every file gets a header, the first one included')
  eq(view.files[1].row, headers[1].row)
  eq(view.files[2].row, headers[2].row)
  eq('b.pl', headers[2].text)

  -- and the header text is what the buffer holds on that row
  local text = vim.api.nvim_buf_get_lines(buf, headers[2].row - 1, headers[2].row, false)
  eq({ 'b.pl' }, text)
end)

test('headers and gaps are highlighted as whole lines', function()
  local buf, view = build({ LUA, PERL })
  local ns = vim.api.nvim_get_namespaces()['gitview.diff']
  local groups = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    eq(nil, m[4].virt_lines, 'no virtual lines are left')
    groups[m[2] + 1] = groups[m[2] + 1] or m[4].hl_group
  end
  for i, l in ipairs(view.lines) do
    if l.kind == 'file' then
      eq('GitViewFileHeader', groups[i], 'row ' .. i)
    end
  end
end)

test('the winbar names the file the cursor is in', function()
  local buf, view = build({ LUA, PERL })
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    width = 60,
    height = 10,
    row = 1,
    col = 1,
  })
  render.configure_window(win, buf)
  vim.g.statusline_winid = win

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  assert(render.winbar():find('a.lua', 1, true), 'expected the first file')
  vim.api.nvim_win_set_cursor(win, { view.files[2].row, 0 })
  assert(render.winbar():find('b.pl', 1, true), 'expected the second file')

  vim.api.nvim_win_close(win, true)
end)

test("a rule runs through every file's header, gutter included", function()
  local buf, view = build({ LUA, PERL })
  local ns = vim.api.nvim_get_namespaces()['gitview.diff']
  local rules = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].virt_text_pos == 'eol' then
      eq('GitViewFileRule', m[4].virt_text[1][2])
      rules[#rules + 1] = m[2] + 1
    end
  end
  eq({ view.files[1].row, view.files[2].row }, rules)

  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    width = 60,
    height = 10,
    row = 1,
    col = 1,
  })
  render.configure_window(win, buf)
  vim.g.statusline_winid = win
  vim.v.lnum = view.files[2].row
  eq('%#GitViewFileRule#' .. ('─'):rep(11) .. ' ', render.statuscolumn())
  vim.v.lnum = view.files[2].row - 1
  eq((' '):rep(12), render.statuscolumn(), 'the blank line in front is left blank')
  vim.api.nvim_win_close(win, true)
end)

test('each header ends with how many lines its file adds and deletes', function()
  local only_add = {
    label = 'c.lua',
    lang = 'lua',
    old = { 'local x = 1' },
    new = { 'local x = 1', 'return x' },
  }
  local buf, view = build({ LUA, only_add })
  local ns = vim.api.nvim_get_namespaces()['gitview.diff']
  local stats = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].virt_text_pos == 'right_align' then
      stats[m[2] + 1] = m[4].virt_text
    end
  end
  eq({
    [view.files[1].row] = {
      { ' ' },
      { '+1', 'GitViewStatAdd' },
      { ' ' },
      { '-1', 'GitViewStatDelete' },
    },
    -- a count of zero is left out
    [view.files[2].row] = { { ' ' }, { '+1', 'GitViewStatAdd' } },
  }, stats)
end)

test('a single-file view still gets its header', function()
  local _, view = build({ LUA })
  eq('file', view.lines[1].kind)
  eq('a.lua', view.lines[1].text)
end)
