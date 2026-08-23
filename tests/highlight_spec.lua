local hl = require('unidiff.highlight')

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

--- @param segs table<integer, unidiff.Seg[]>
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
