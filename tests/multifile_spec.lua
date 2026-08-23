local dlib = require('unidiff.diff')
local hl = require('unidiff.highlight')
local render = require('unidiff.render')

local test, eq = _G.test, _G.eq

--- Assemble a view the way init.build_view does, so the concatenation rules are
--- exercised without needing a git repository.
--- @param sources {label:string, lang:string, old:string[], new:string[]}[]
--- @return integer bufnr, unidiff.View
local function build(sources)
  local lines, files, hunk_rows, gaps = {}, {}, {}, {}
  for _, src in ipairs(sources) do
    local hunks = dlib.hunks(src.old, src.new)
    local flines, fhunks, fgaps = dlib.build(hunks, src.old, src.new, 3)
    local offset = #lines
    files[#files + 1] = {
      path = '/tmp/' .. src.label,
      label = src.label,
      old_buf = hl.ghost_buffer(src.old, src.lang),
      new_buf = hl.ghost_buffer(src.new, src.lang),
      lang = src.lang,
      row = offset + 1,
    }
    for _, l in ipairs(flines) do
      l.file = #files
      lines[#lines + 1] = l
    end
    for _, r in ipairs(fhunks) do
      hunk_rows[#hunk_rows + 1] = r + offset
    end
    for _, g in ipairs(fgaps) do
      gaps[#gaps + 1] = { row = g.row + offset, count = g.count }
    end
  end
  local view =
    { lines = lines, files = files, hunk_rows = hunk_rows, gaps = gaps, rev = 'HEAD' }
  local buf = render.render(view)
  for _, f in ipairs(files) do
    vim.api.nvim_buf_delete(f.old_buf, { force = true })
    vim.api.nvim_buf_delete(f.new_buf, { force = true })
  end
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
  eq(1, view.files[1].row)
  eq(4, view.files[2].row)
  eq(view.lines[view.files[2].row].file, 2)
  eq(#view.lines, #vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end)

test('every line still holds only source text', function()
  local buf, view = build({ LUA, PERL })
  local text = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(view.lines) do
    eq(l.text, text[i], 'row ' .. i)
  end
end)

test('each file is highlighted with its own language', function()
  vim.cmd('syntax enable')
  local buf, view = build({ LUA, PERL })
  local ns = vim.api.nvim_get_namespaces()['unidiff.syntax']
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
  -- a.lua renders as del, add and one context line before b.pl starts
  eq({ 1, 4 }, view.hunk_rows)
end)

test('file headers are virtual lines, and the first file has none', function()
  local buf, view = build({ LUA, PERL })
  local ns = vim.api.nvim_get_namespaces()['unidiff.diff']
  local headers = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].virt_lines then
      for _, vline in ipairs(m[4].virt_lines) do
        for _, chunk in ipairs(vline) do
          if chunk[2] == 'UnidiffFileHeader' then
            headers[#headers + 1] = { row = m[2], text = chunk[1] }
          end
        end
      end
    end
  end
  eq(1, #headers, 'only the second file gets a virtual header')
  eq(view.files[2].row - 1, headers[1].row)
  assert(headers[1].text:find('b.pl', 1, true), 'header should name the file')
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

test('a single-file view carries no virtual header', function()
  local buf = build({ LUA })
  local ns = vim.api.nvim_get_namespaces()['unidiff.diff']
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    for _, vline in ipairs(m[4].virt_lines or {}) do
      for _, chunk in ipairs(vline) do
        eq(nil, chunk[2] == 'UnidiffFileHeader' and 'header' or nil)
      end
    end
  end
end)
