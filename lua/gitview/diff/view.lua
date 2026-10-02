--- Turning sources into the one structure a diff buffer is drawn from.
local dlib = require('gitview.diff.lines')
local hl = require('gitview.diff.highlight')
local mixed = require('gitview.diff.mixed')

local M = {}

--- Concatenate the diffs of several sources into one view.
---
--- Nothing here reads git or the editor: a source already carries both versions
--- and its filetype. The ghost buffers it creates are the view's only resource,
--- and `dispose` is what frees them.
---
--- @param sources gitview.Source[]
--- @param rev string
--- @param context integer
--- @param diff_opts {algorithm:string, linematch:integer}
--- @return gitview.View? view nil when nothing differs
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

--- The lines that introduce a commit: its subject, who wrote it and when, the
--- body, and the stat. Blank lines part them, and the body's own blank lines are
--- kept as written.
--- @param detail gitview.CommitDetail
--- @return gitview.Line[]
function M.commit_header(detail)
  local out = {}
  local function add(text, kind)
    out[#out + 1] = { text = text, kind = kind }
  end
  add(detail.message[1] or '', 'subject')
  add(('%s   %s'):format(detail.author, detail.date), 'author')

  -- A message has a blank line after its subject by convention only, and some
  -- are written with more than one; the header puts exactly one there.
  local first, last = 2, #detail.message
  while first <= last and vim.trim(detail.message[first]) == '' do
    first = first + 1
  end
  if first <= last then
    add('', 'blank')
    for i = first, last do
      add(detail.message[i], 'body')
    end
  end

  if #detail.stat > 0 then
    add('', 'blank')
    for _, text in ipairs(detail.stat) do
      add(text, 'stat')
    end
  end
  return out
end

--- The header a commit can be given from the log alone: its subject, and who
--- wrote it how long ago. It stands in for `commit_header` while the message
--- and stat are still being read.
--- @param commit gitview.Commit
--- @return gitview.Line[]
function M.commit_summary(commit)
  return {
    { text = commit.subject, kind = 'subject' },
    { text = ('%s   %s'):format(commit.author, commit.when), kind = 'author' },
  }
end

--- A view of nothing yet: one line saying why, under a header when there is
--- one. Being a view rather than a notice, it keeps the header's fold for the
--- view that replaces it.
--- @param rev string
--- @param text string
--- @param header gitview.Line[]?
--- @return gitview.View
function M.placeholder(rev, text, header)
  local view = {
    lines = { { text = text, kind = 'notice' } },
    files = {},
    hunk_rows = {},
    file_rows = {},
    rev = rev,
  }
  if header then
    M.prepend(view, header)
  end
  return view
end

--- Put a header above everything a view shows.
---
--- A blank line parts it from the first file, as one parts two files, and is
--- not part of the header: it stays in view while the header is folded.
--- @param view gitview.View
--- @param header gitview.Line[]
function M.prepend(view, header)
  local shift = #header + 1
  local lines = vim.list_extend({}, header)
  lines[#lines + 1] = { text = '', kind = 'blank' }
  view.lines = vim.list_extend(lines, view.lines)
  for i, r in ipairs(view.hunk_rows) do
    view.hunk_rows[i] = r + shift
  end
  for i, r in ipairs(view.file_rows) do
    view.file_rows[i] = r + shift
  end
  for _, f in ipairs(view.files) do
    f.row = f.row + shift
  end
  view.header_rows = #header
end

--- Free the ghost buffers. They exist only to be read by `highlight.collect`, and
--- a view handed to `render.draw` is freed by it once its syntax has been
--- replayed onto the diff buffer, which may be some time after the draw.
---
--- The handles are cleared as well, so that a later attempt to read a version
--- fails outright rather than addressing some unrelated buffer.
--- @param view gitview.View
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

--- What a view could not show, for its winbar. Dropping either silently would
--- hide a real change: a pure rename or a mode change produces no hunks, and a
--- binary file has no versions that can be diffed.
--- @param skipped gitview.Skipped
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
  add(#skipped.conflicted, 'conflicted')
  add(unchanged, 'without textual change')
  if #notes > 0 then
    return '(' .. table.concat(notes, ', ') .. ' not shown)'
  end
end

return M
