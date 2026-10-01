local hl = require('gitview.diff.highlight')

local test, eq = _G.test, _G.eq

-- The legacy path only exists when :syntax is on.
vim.cmd('syntax enable')

--- Perl has no bundled Tree-sitter parser but does ship a :syntax file, which
--- makes it the fixture for the fallback path.
local PERL = {
  'my $x = "hello";',
  'sub greet {',
  '    my ($name) = @_;',
  '    return "hi $name";',
  '}',
}

--- @param segs table<integer, gitview.Seg[]>
--- @return string[]
local function groups(segs, row)
  local out = {}
  for _, s in ipairs(segs[row] or {}) do
    out[#out + 1] = s.hl_group
  end
  return out
end

test('falls back to legacy syntax when no parser exists', function()
  local buf = hl.ghost_buffer(PERL, 'perl')
  eq(nil, (vim.treesitter.get_parser(buf, 'perl')), 'fixture must have no parser')

  local segs = hl.collect(buf, 'perl')
  assert(next(segs) ~= nil, 'expected legacy syntax segments')
  local g = groups(segs, 0)
  assert(#g > 0, 'first row should be highlighted')
  for _, name in ipairs(g) do
    assert(name:match('^perl'), 'expected a perl syntax group, got ' .. name)
  end
end)

test('legacy segments cover the right text', function()
  local buf = hl.ghost_buffer(PERL, 'perl')
  local segs = hl.collect(buf, 'perl')
  local found = {}
  for _, s in ipairs(segs[0]) do
    found[PERL[1]:sub(s.start_col + 1, s.end_col)] = s.hl_group
  end
  assert(found['my'], 'expected a segment covering exactly "my", got ' .. vim.inspect(found))
  assert(found['$x'], 'expected a segment covering exactly "$x", got ' .. vim.inspect(found))
end)

test('legacy path honours the requested rows', function()
  local buf = hl.ghost_buffer(PERL, 'perl')
  local segs = hl.collect(buf, 'perl', { [2] = true })
  eq({ 2 }, vim.tbl_keys(segs))
end)

test('legacy path keeps context from lines it never probed', function()
  -- The middle of a POD block is only a POD group because of `=pod` far above,
  -- and that line is deliberately left out of the requested rows.
  local lines = { 'my $a = 1;', '', '=pod' }
  for i = 1, 40 do
    lines[#lines + 1] = 'documentation line ' .. i
  end
  lines[#lines + 1] = '=cut'
  local buf = hl.ghost_buffer(lines, 'perl')

  local row = 32 -- 0-based, well inside the block
  eq('documentation line 30', lines[row + 1])
  local segs = hl.collect(buf, 'perl', { [row] = true })
  eq({ 'perlPOD' }, groups(segs, row))
end)

test('legacy segments never split a multibyte character', function()
  local line = 'my $msg = "こんにちは world";'
  local buf = hl.ghost_buffer({ line }, 'perl')
  for _, s in ipairs(hl.collect(buf, 'perl')[0]) do
    local before = line:sub(1, s.start_col)
    local frag = line:sub(s.start_col + 1, s.end_col)
    eq(
      frag,
      vim.fn.strcharpart(line, vim.fn.strchars(before), vim.fn.strchars(frag)),
      'segment ' .. vim.inspect(frag) .. ' is not on character boundaries'
    )
  end
end)

test('treesitter wins when a parser is available', function()
  local buf = hl.ghost_buffer({ 'local x = 1' }, 'lua')
  for _, s in ipairs(hl.collect(buf, 'lua')[0]) do
    assert(s.hl_group:sub(1, 1) == '@', 'expected a treesitter group, got ' .. s.hl_group)
  end
end)

test('both paths report the same priority layer', function()
  local ts = hl.collect(hl.ghost_buffer({ 'local x = 1' }, 'lua'), 'lua')[0][1]
  local syn = hl.collect(hl.ghost_buffer(PERL, 'perl'), 'perl')[0][1]
  eq(ts.priority, syn.priority)
end)

--- A file with a long string, so multi-row captures are in play.
local LUA_DOC = { 'local a = 1', 'local doc = [[' }
for i = 1, 30 do
  LUA_DOC[#LUA_DOC + 1] = 'prose line ' .. i
end
LUA_DOC[#LUA_DOC + 1] = ']]'
LUA_DOC[#LUA_DOC + 1] = 'return a'

test('treesitter path honours the requested rows', function()
  local buf = hl.ghost_buffer(LUA_DOC, 'lua')
  local segs = hl.collect(buf, 'lua', { [0] = true, [33] = true })
  eq({ 0, 33 }, vim.fn.sort(vim.tbl_keys(segs), function(a, b)
    return a - b
  end))
end)

test('restricting rows does not change what those rows get', function()
  -- The parse still covers the whole buffer, so a row deep inside the string
  -- must come out identical whether or not its neighbours were requested.
  local buf = hl.ghost_buffer(LUA_DOC, 'lua')
  local full = hl.collect(buf, 'lua')
  for _, row in ipairs({ 0, 1, 20, 32, 33 }) do
    eq(full[row], hl.collect(buf, 'lua', { [row] = true })[row], 'row ' .. row)
  end
end)

test('a row inside a multi-line string keeps its string capture', function()
  local buf = hl.ghost_buffer(LUA_DOC, 'lua')
  local segs = hl.collect(buf, 'lua', { [20] = true })
  eq('prose line 19', LUA_DOC[21])
  local found = false
  for _, s in ipairs(segs[20] or {}) do
    found = found or s.hl_group == '@string.lua'
  end
  assert(found, 'expected @string.lua, got ' .. vim.inspect(segs[20]))
end)

test('a capture spanning two requested ranges is not duplicated', function()
  local buf = hl.ghost_buffer(LUA_DOC, 'lua')
  -- two disjoint ranges, both inside the same multi-row string capture
  local segs = hl.collect(buf, 'lua', { [10] = true, [20] = true })
  for _, row in ipairs({ 10, 20 }) do
    local strings = 0
    for _, s in ipairs(segs[row] or {}) do
      if s.hl_group == '@string.lua' then
        strings = strings + 1
      end
    end
    eq(1, strings, 'row ' .. row .. ' should carry one string segment')
  end
end)

test('has_parser tells the two highlight paths apart', function()
  eq(true, hl.has_parser('lua'))
  -- `vim.treesitter.language.add` reports failure as nil, not false
  eq(false, hl.has_parser('perl'))
  eq(false, hl.has_parser('nosuchlanguage'))
  eq(false, hl.has_parser(''))
end)

test('a ghost buffer loads no syntax when treesitter can highlight it', function()
  -- It would load a syntax file for nothing.
  local buf = hl.ghost_buffer({ 'local x = 1' }, 'lua', 'lua')
  eq('', vim.bo[buf].filetype)
  eq('', vim.bo[buf].syntax)
  assert(hl.collect(buf, 'lua')[0], 'highlights should still be collected')
end)

test('a ghost buffer sets syntax alone when the legacy path is needed', function()
  -- 'filetype' would also run ftplugins and FileType autocommands.
  local buf = hl.ghost_buffer(PERL, 'perl', 'perl')
  eq('perl', vim.bo[buf].syntax)
  eq('', vim.bo[buf].filetype)
  assert(next(hl.collect(buf, 'perl')), 'legacy highlights should still work')
end)

test('a filetype listed in no_highlight counts as none', function()
  local config = require('gitview.config')
  local source = require('gitview.diff.source')
  local kept = config.values.no_highlight
  eq('scss', source.filetype_of('/tmp/a.scss'))
  config.values.no_highlight = { 'scss' }
  eq('', source.filetype_of('/tmp/a.scss'))
  eq('css', source.filetype_of('/tmp/a.css'))
  config.values.no_highlight = kept
end)

test('a ghost buffer with no filetype is left unhighlighted', function()
  local buf = hl.ghost_buffer(PERL, '', '')
  eq('', vim.bo[buf].filetype)
  eq('', vim.bo[buf].syntax)
  eq({}, hl.collect(buf, ''))
end)
