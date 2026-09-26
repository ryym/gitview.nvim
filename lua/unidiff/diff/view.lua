--- Turning sources into the one structure a diff buffer is drawn from.
local dlib = require('unidiff.diff.lines')
local hl = require('unidiff.diff.highlight')
local mixed = require('unidiff.diff.mixed')

local M = {}

--- Concatenate the diffs of several sources into one view.
---
--- Nothing here reads git or the editor: a source already carries both versions
--- and its filetype. The ghost buffers it creates are the view's only resource,
--- and `dispose` is what frees them.
---
--- @param sources unidiff.Source[]
--- @param rev string
--- @param context integer
--- @param diff_opts {algorithm:string, linematch:integer}
--- @return unidiff.View? view nil when nothing differs
--- @return string[] unchanged labels of sources with no textual difference,
---         such as a pure rename or a mode change
function M.build(sources, rev, context, diff_opts)
  local lines, files, hunk_rows, file_rows = {}, {}, {}, {}
  local unchanged = {}
  -- A third version is what makes a view mixed, so the sources say so and the
  -- caller has nothing to add afterwards.
  local is_mixed = false

  for _, src in ipairs(sources) do
    local flines, fhunks
    if src.index_lines then
      is_mixed = true
      flines, fhunks =
        mixed.build(src.old_lines, src.index_lines, src.new_lines, context, diff_opts)
    else
      local hunks = dlib.hunks(src.old_lines, src.new_lines, diff_opts)
      if #hunks > 0 then
        flines, fhunks = dlib.build(hunks, src.old_lines, src.new_lines, context)
      end
    end
    if not flines then
      unchanged[#unchanged + 1] = src.label
    else
      local ft = src.ft
      local lang = vim.treesitter.language.get_lang(ft) or ft

      -- A blank line keeps the header off the previous file's last diff line.
      if #lines > 0 then
        lines[#lines + 1] = { text = '', kind = 'blank' }
      end
      lines[#lines + 1] = { text = src.label, kind = 'file' }
      local offset = #lines

      files[#files + 1] = {
        path = src.path,
        label = src.label,
        old_buf = hl.ghost_buffer(src.old_lines, ft, lang),
        new_buf = hl.ghost_buffer(src.new_lines, ft, lang),
        index_buf = src.index_lines and hl.ghost_buffer(src.index_lines, ft, lang),
        lang = lang,
        row = offset,
      }
      file_rows[#file_rows + 1] = offset
      local index = #files

      for _, l in ipairs(flines) do
        l.file = index
        lines[#lines + 1] = l
      end
      for _, r in ipairs(fhunks) do
        hunk_rows[#hunk_rows + 1] = r + offset
      end
    end
  end

  if #files == 0 then
    return nil, unchanged
  end
  return {
    lines = lines,
    files = files,
    hunk_rows = hunk_rows,
    file_rows = file_rows,
    rev = rev,
    mixed = is_mixed or nil,
  }, unchanged
end

--- Free the ghost buffers. They exist only to be read by `highlight.collect`,
--- which has already run by the time a view has been drawn; the highlights now
--- live in the diff buffer as extmarks and do not refer back.
---
--- The handles are cleared as well, so that a later attempt to read a version
--- fails outright rather than addressing some unrelated buffer.
--- @param view unidiff.View
function M.dispose(view)
  for _, f in ipairs(view.files) do
    for _, key in ipairs({ 'old_buf', 'new_buf', 'index_buf' }) do
      if f[key] then
        vim.api.nvim_buf_delete(f[key], { force = true })
        f[key] = nil
      end
    end
  end
end

--- What a view could not show, for its winbar. Dropping any of these silently
--- would hide a real change: a pure rename or a mode change produces no hunks,
--- and a binary or unmerged file has no versions that can be diffed.
--- @param skipped unidiff.Skipped
--- @param unchanged integer
--- @return string?
function M.skipped_note(skipped, unchanged)
  local notes = {}
  local function add(n, what)
    if n > 0 then
      notes[#notes + 1] = ('%d %s'):format(n, what)
    end
  end
  add(#skipped.binary, 'binary')
  add(#skipped.conflicted, 'unmerged')
  add(unchanged, 'without textual change')
  if #notes > 0 then
    return '(' .. table.concat(notes, ', ') .. ' not shown)'
  end
end

return M
