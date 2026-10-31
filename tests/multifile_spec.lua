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
    if m[4].hl_group ~= 'GitViewFileHeaderBg' then
      groups[m[2] + 1] = groups[m[2] + 1] or m[4].hl_group
    end
  end
  for i, l in ipairs(view.lines) do
    if l.kind == 'file' then
      eq('GitViewFileHeader', groups[i], 'row ' .. i)
    end
  end
end)

test('the winbar names the file the top of the window is in', function()
  local buf, view = build({ LUA, PERL })
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    width = 60,
    height = 10,
    row = 1,
    col = 1,
  })
  render.set_window_defaults(win)
  render.fix_window(win)
  vim.g.statusline_winid = win
  local function scroll_to(top)
    vim.api.nvim_win_call(win, function()
      vim.wo.foldenable = false
      vim.fn.winrestview({ topline = top, lnum = top })
    end)
  end

  scroll_to(view.files[1].row)
  local bar = render.winbar()
  assert(not bar:find('a.lua', 1, true), 'a header on screen is not repeated: ' .. bar)
  scroll_to(view.files[1].row + 1)
  assert(render.winbar():find('a.lua', 1, true), 'expected the first file')
  scroll_to(view.files[2].row)
  assert(render.winbar():find('a.lua', 1, true), 'expected the first file still')
  scroll_to(view.files[2].row + 1)
  assert(render.winbar():find('b.pl', 1, true), 'expected the second file')

  -- the cursor further down does not change it
  scroll_to(view.files[1].row + 1)
  vim.api.nvim_win_set_cursor(win, { view.files[2].row + 1, 0 })
  eq(view.files[1].row + 1, vim.fn.line('w0', win), 'the window did not scroll')
  assert(render.winbar():find('a.lua', 1, true), 'expected the first file')

  vim.api.nvim_win_close(win, true)
end)

-- The winbar is bold by default, so the text around the file is drawn in a group
-- that does not combine with it, and the file alone is left bold. A `%*` would
-- go back to the winbar's bold.
test('the winbar leaves only the file bold', function()
  local buf, view = build({ LUA, PERL })
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    width = 60,
    height = 10,
    row = 1,
    col = 1,
  })
  render.set_window_defaults(win)
  render.fix_window(win)
  vim.g.statusline_winid = win
  vim.api.nvim_win_call(win, function()
    vim.wo.foldenable = false
    vim.fn.winrestview({ topline = view.files[1].row + 1, lnum = view.files[1].row + 1 })
  end)

  local bar = render.winbar()
  local head = '%#GitViewWinBarText# %#GitViewFileHeader#a.lua%#GitViewWinBarText# @ '
  eq(head, bar:sub(1, #head))
  assert(not bar:find('%*', 1, true), bar)

  vim.api.nvim_win_close(win, true)
end)

--- What the gutter shows on `row` of `buf`, as 'statuscolumn' draws it.
--- @param buf integer
--- @param row integer
--- @return string
local function gutter_at(buf, row)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    width = 60,
    height = 10,
    row = 1,
    col = 1,
  })
  render.set_window_defaults(win)
  render.fix_window(win)
  vim.g.statusline_winid = win
  vim.v.lnum = row
  local gutter = render.statuscolumn()
  vim.api.nvim_win_close(win, true)
  return gutter
end

test("each header's gutter carries its background", function()
  local buf, view = build({ LUA, PERL })
  local gutter = gutter_at(buf, view.files[2].row)
  assert(vim.startswith(gutter, '%#GitViewFileHeaderBg# '), 'expected the background: ' .. gutter)
  eq((' '):rep(12), gutter_at(buf, view.files[2].row - 1), 'the blank line in front is left blank')
end)

test('buffer_lnum puts the rows own numbers before the gutter', function()
  local config = require('gitview.config')
  local buf, view = build({ LUA, PERL })
  local header = view.files[2].row
  local plain_header, plain_blank = gutter_at(buf, header), gutter_at(buf, header - 1)
  config.values.buffer_lnum = true
  local ok, err = pcall(function()
    eq('%#GitViewFileHeaderBg#%l ' .. plain_header, gutter_at(buf, header), 'the band runs through it')
    eq('%l ' .. plain_blank, gutter_at(buf, header - 1))
  end)
  config.values.buffer_lnum = false
  assert(ok, err)
end)

test("buffer_lnum numbers rows as the user's 'number' and 'relativenumber' say", function()
  local config = require('gitview.config')
  local buf = build({ LUA })
  --- @param number boolean
  --- @param relative boolean
  --- @return {number: boolean, relativenumber: boolean}
  local function configured(number, relative)
    vim.go.number, vim.go.relativenumber = number, relative
    local win = vim.api.nvim_open_win(buf, false, {
      relative = 'editor',
      width = 60,
      height = 10,
      row = 1,
      col = 1,
    })
    render.set_window_defaults(win)
    render.fix_window(win)
    local got = { number = vim.wo[win].number, relativenumber = vim.wo[win].relativenumber }
    vim.api.nvim_win_close(win, true)
    return got
  end
  local kept = { vim.go.number, vim.go.relativenumber }
  config.values.buffer_lnum = true
  local ok, err = pcall(function()
    eq({ number = false, relativenumber = true }, configured(false, true))
    eq({ number = true, relativenumber = true }, configured(true, true))
    eq({ number = true, relativenumber = false }, configured(false, false), 'both off would show nothing')
    config.values.buffer_lnum = false
    eq({ number = false, relativenumber = false }, configured(true, true), 'off, they are not shown')
  end)
  config.values.buffer_lnum = false
  vim.go.number, vim.go.relativenumber = kept[1], kept[2]
  assert(ok, err)
end)

test("each header's gutter ends with how many lines its file adds and deletes", function()
  local only_add = {
    label = 'c.lua',
    lang = 'lua',
    old = { 'local x = 1' },
    new = { 'local x = 1', 'return x' },
  }
  local buf, view = build({ LUA, only_add })
  eq(
    '%#GitViewFileHeaderBg#' .. (' '):rep(5) .. ' %#GitViewFileHeaderStatAdd#+1 %#GitViewFileHeaderStatDelete#-1 ',
    gutter_at(buf, view.files[1].row)
  )
  -- a count of zero is left out
  eq(
    '%#GitViewFileHeaderBg#' .. (' '):rep(8) .. ' %#GitViewFileHeaderStatAdd#+1 ',
    gutter_at(buf, view.files[2].row)
  )
end)

--- @param n integer
--- @param tag string
--- @return string[]
local function numbered(n, tag)
  local lines = {}
  for i = 1, n do
    lines[i] = tag .. i
  end
  return lines
end

test('a count of up to four digits fills the gutter as it is', function()
  local buf, view = build({
    { label = 'big.txt', lang = 'text', old = numbered(9999, 'old'), new = numbered(9999, 'new') },
  })
  eq(
    '%#GitViewFileHeaderBg#%#GitViewFileHeaderStatAdd#+9999 %#GitViewFileHeaderStatDelete#-9999 ',
    gutter_at(buf, view.files[1].row)
  )
end)

test('a count past four digits is rounded down to thousands', function()
  local buf, view = build({
    { label = 'big.txt', lang = 'text', old = numbered(10000, 'old'), new = numbered(12999, 'new') },
  })
  eq(
    '%#GitViewFileHeaderBg#' .. (' '):rep(1) .. ' %#GitViewFileHeaderStatAdd#+12k %#GitViewFileHeaderStatDelete#-10k ',
    gutter_at(buf, view.files[1].row)
  )
end)

test('a single-file view still gets its header', function()
  local _, view = build({ LUA })
  eq('file', view.lines[1].kind)
  eq('a.lua', view.lines[1].text)
end)

test('a changed line is told apart by the color of its number, not a sign', function()
  local buf = build({ LUA })
  eq('%#GitViewDeleteLnum#   1        ', gutter_at(buf, 2))
  eq('     %#GitViewAddLnum#   1   ', gutter_at(buf, 3))
  eq('%#GitViewOldLnum#   2 %#GitViewNewLnum#   2   ', gutter_at(buf, 4))
end)

test('a mixed view marks with a bar each row the index has changed', function()
  local view = require('gitview.diff.view').build({
    {
      label = 'm.txt',
      path = '/tmp/m.txt',
      ft = 'text',
      old_lines = { 'x' },
      index_lines = { 'X' },
      new_lines = { 'XX' },
    },
  }, 'HEAD, staged + unstaged', 3, { algorithm = 'histogram', linematch = 0 })
  local buf = render.render(assert(view))
  local gutters = {}
  for row, l in ipairs(view.lines) do
    if l.stage then
      gutters[l.stage] = gutter_at(buf, row)
    end
  end
  eq({
    staged = '%#GitViewDeleteLnum#   1      %#GitViewStagedDeleteBar#┃ ',
    -- in neither HEAD nor the working tree, so it has no numbers
    index = '          %#GitViewStagedAddBar#┃ ',
    unstaged = '     %#GitViewAddLnum#   1   ',
  }, gutters)
end)

--- A view of one mixed source with only `layer` shown.
--- @param head string[]
--- @param index string[]
--- @param work string[]
--- @param layer gitview.Layer
--- @param context integer?
--- @return gitview.View
local function layer_view(head, index, work, layer, context)
  local view = require('gitview.diff.view').build({
    {
      label = 'm.txt',
      path = '/tmp/m.txt',
      ft = 'text',
      old_lines = head,
      index_lines = index,
      new_lines = work,
    },
  }, 'HEAD, ' .. layer, context or 3, { algorithm = 'histogram', linematch = 0, layer = layer })
  return assert(view)
end

--- The gutter of every source row, by its text.
--- @param view gitview.View
--- @return table<string, string>
local function gutters_by_text(view)
  local buf = render.render(view)
  local out = {}
  for row, l in ipairs(view.lines) do
    if dlib.source_kinds[l.kind] then
      out[l.text] = gutter_at(buf, row)
    end
  end
  return out
end

-- The index line numbers differ from both HEAD's and the working tree's here,
-- so each column shows which version it was taken from.
test('a layer shown alone is numbered by the two versions it compares', function()
  local head, index, work = { 'a' }, { 'n', 'a', 'b' }, { 'a', 'b', 'w' }
  eq({
    n = '     %#GitViewAddLnum#   1   ',
    a = '%#GitViewOldLnum#   1 %#GitViewNewLnum#   2   ',
    b = '     %#GitViewAddLnum#   3   ',
  }, gutters_by_text(layer_view(head, index, work, 'staged')))
  eq({
    n = '%#GitViewDeleteLnum#   1        ',
    a = '%#GitViewOldLnum#   2 %#GitViewNewLnum#   1   ',
    b = '%#GitViewOldLnum#   3 %#GitViewNewLnum#   2   ',
    -- placed in front of an index line past the end, which is no line of it
    w = '     %#GitViewAddLnum#   3   ',
  }, gutters_by_text(layer_view(head, index, work, 'unstaged')))
end)

test("a layer shown alone counts its own changes in the file's header", function()
  local head, index, work = { 'a' }, { 'a', 'b', 'c' }, { 'a', 'b', 'c', 'd' }
  for layer, count in pairs({ staged = '#+2 ', unstaged = '#+1 ' }) do
    local view = layer_view(head, index, work, layer)
    local header = gutter_at(render.render(view), view.files[1].row)
    assert(header:find(count, 1, true), layer .. ': ' .. header)
  end
end)

test('a layer shown alone has no bar and the colors of a plain diff', function()
  local view = layer_view({ 'x' }, { 'X' }, { 'X' }, 'staged')
  local buf = render.render(view)
  local ns = vim.api.nvim_get_namespaces()['gitview.diff']
  local groups = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    groups[view.lines[m[2] + 1].text] = m[4].hl_group
  end
  eq({ ['m.txt'] = 'GitViewFileHeader', x = 'GitViewDelete', X = 'GitViewAdd' }, groups)
  eq('%#GitViewDeleteLnum#   1        ', gutter_at(buf, 2))
  eq('     %#GitViewAddLnum#   1   ', gutter_at(buf, 3))
end)

-- Staged alone, the unchanged rows are those HEAD and the index share, and the
-- working tree may have dropped them: a fold can start at a row with no
-- working-tree number to be remembered by.
test('a fold of the staged layer alone stays open across a redraw', function()
  local head = { 'a', 'b', 'c', 'd', 'e', 'f', 'z' }
  local index = { 'a', 'b', 'c', 'd', 'e', 'f', 'Z' }
  local work = { 'f', 'Z' }
  local view = layer_view(head, index, work, 'staged', 1)
  local buf = render.render(view)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    width = 60,
    height = 20,
    row = 1,
    col = 1,
  })
  render.set_window_defaults(win)
  render.fix_window(win)
  eq(nil, view.lines[2].new_lnum)
  assert(view.lines[2].folded, 'expected the run to fold from its first row')
  vim.api.nvim_win_call(win, function()
    vim.cmd('2foldopen')
  end)
  render.draw(buf, layer_view(head, index, work, 'staged', 1))
  local open = vim.api.nvim_win_call(win, function()
    return vim.fn.foldclosed(2) == -1
  end)
  vim.api.nvim_win_close(win, true)
  eq(true, open)
end)
