local keymap = require('gitview.diff.keymap')
local vlib = require('gitview.diff.view')

local test, eq = _G.test, _G.eq

--- A view of `f.txt` in /repo with only `layer` shown.
--- @param head string[]
--- @param index string[]
--- @param work string[]
--- @param layer gitview.Layer
--- @return gitview.View
local function layer_view(head, index, work, layer)
  local view = vlib.build({
    {
      label = 'f.txt',
      path = '/repo/f.txt',
      ft = 'text',
      old_lines = head,
      index_lines = index,
      new_lines = work,
      old_rev = 'HEAD',
    },
  }, 'HEAD, ' .. layer, 3, { algorithm = 'histogram', linematch = 0, layer = layer })
  return assert(view)
end

--- What `gy` copies for the row of `text` alone.
--- @param view gitview.View
--- @param text string
--- @return string
local function ref_of(view, text)
  for row, l in ipairs(view.lines) do
    if l.file and l.text == text then
      return keymap.references(view, row, row, '/repo')[1]
    end
  end
  error('no row ' .. text)
end

-- `x` is staged, then dropped from the working tree, and `b` is only dropped
-- from it: the index numbers both, as the gutter does.
test('keymap: a row only the index has is given by its index number', function()
  local head, index, work = { 'a', 'b' }, { 'a', 'x', 'b' }, { 'a' }
  local staged = layer_view(head, index, work, 'staged')
  eq('f.txt:2 (in the index)', ref_of(staged, 'x'))
  eq('f.txt:3 (in the index)', ref_of(staged, 'b'))
  local unstaged = layer_view(head, index, work, 'unstaged')
  eq('f.txt:2 (deleted from the index)', ref_of(unstaged, 'x'))
  eq('f.txt:3 (deleted from the index)', ref_of(unstaged, 'b'))
end)

test('keymap: a row HEAD alone has is still given by HEAD', function()
  local view = layer_view({ 'a', 'b' }, { 'a' }, { 'a' }, 'staged')
  eq('f.txt:2 (deleted from HEAD)', ref_of(view, 'b'))
end)
