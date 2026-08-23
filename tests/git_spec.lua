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
