local git = require('unidiff.git')

local test, eq = _G.test, _G.eq

--- `git diff --name-status -z` emits NUL-separated records.
local function z(...)
  return table.concat({ ... }, '\0') .. '\0'
end

test('parses ordinary statuses', function()
  eq({
    { status = 'M', path = 'a.txt', old_path = 'a.txt', binary = false },
    { status = 'A', path = 'b.txt', old_path = 'b.txt', binary = false },
    { status = 'D', path = 'c.txt', old_path = 'c.txt', binary = false },
  }, git.parse_name_status(z('M', 'a.txt', 'A', 'b.txt', 'D', 'c.txt')))
end)

test('parses renames as three records', function()
  -- The status carries a similarity score and the two paths follow it.
  eq({
    { status = 'R', path = 'new.txt', old_path = 'old.txt', binary = false },
    { status = 'M', path = 'z.txt', old_path = 'z.txt', binary = false },
  }, git.parse_name_status(z('R100', 'old.txt', 'new.txt', 'M', 'z.txt')))
end)

test('keeps paths containing spaces intact', function()
  local changes = git.parse_name_status(z('M', 'dir with space/sp ace.txt'))
  eq('dir with space/sp ace.txt', changes[1].path)
end)

test('parses an empty diff', function()
  eq({}, git.parse_name_status(''))
end)

test('finds binary paths in numstat', function()
  local out = z('1\t0\ttext.txt', '-\t-\timage.png')
  eq({ ['image.png'] = true }, git.parse_binary(out))
end)

test('skips the empty path field renames leave in numstat', function()
  -- A renamed entry is `add<TAB>del<TAB>` followed by the old and new paths.
  local out = z('0\t0\t', 'old.txt', 'new.txt', '-\t-\tblob.bin')
  eq({ ['blob.bin'] = true }, git.parse_binary(out))
end)

test('marks a binary rename by its new path', function()
  local out = z('-\t-\t', 'old.bin', 'new.bin')
  eq({ ['new.bin'] = true }, git.parse_binary(out))
end)

test('parses a cat-file batch stream', function()
  -- `<sha> <type> <size>` then exactly size bytes, then a newline.
  local out = table.concat({
    ('a'):rep(40) .. ' blob 7\nfoo\nbar\n',
    ('b'):rep(40) .. ' blob 4\nbaz\n\n',
  })
  eq({ { 'foo', 'bar' }, { 'baz' } }, git.parse_batch(out))
end)

test('reports missing objects in place', function()
  local out = table.concat({
    'HEAD:gone.txt missing\n',
    ('a'):rep(40) .. ' blob 4\nhey\n\n',
  })
  eq({ false, { 'hey' } }, git.parse_batch(out))
end)

test('a header line inside the content is not mistaken for a header', function()
  -- Content that looks like a batch header must be consumed by its size, not
  -- rescanned; only positional order links a result back to its request.
  local fake = ('c'):rep(40) .. ' blob 99'
  local body = fake .. '\ntail'
  local out = ('a'):rep(40) .. (' blob %d\n'):format(#body) .. body .. '\n'
  eq({ { fake, 'tail' } }, git.parse_batch(out))
end)

test('parses an empty batch', function()
  eq({}, git.parse_batch(''))
end)

test('keeps an empty blob distinct from a missing one', function()
  local out = ('a'):rep(40) .. ' blob 0\n\n'
  eq({ {} }, git.parse_batch(out))
end)

test('parses a NUL-separated path list', function()
  -- The stream is terminated rather than separated, so the trailing empty
  -- field is not a path.
  eq({ 'a.txt', 'dir/b b.txt' }, git.parse_paths(z('a.txt', 'dir/b b.txt')))
  eq({}, git.parse_paths(''))
end)
