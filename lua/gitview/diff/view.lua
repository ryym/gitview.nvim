--- Turning sources into the one structure a diff buffer is drawn from.
local conflict = require('gitview.diff.conflict')
local dlib = require('gitview.diff.lines')
local hl = require('gitview.diff.highlight')
local mixed = require('gitview.diff.mixed')

local M = {}

--- Sources a view has no lines for, by label.
--- @class gitview.LeftOut
--- @field unchanged string[] no textual difference, such as a pure rename or a
---        mode change
--- @field unmarked string[] unmerged, with no conflict marked out: one side
---        deleted the file, or the markers were removed by hand

--- Concatenate the diffs of several sources into one view.
---
--- Nothing here reads git or the editor: a source already carries both versions
--- and its filetype. The ghost buffers it creates are the view's only resource,
--- and `dispose` is what frees them.
---
--- An unmerged source is shown as its working tree has it rather than as a
--- diff, with each conflict where a hunk would be.
---
--- @param sources gitview.Source[]
--- @param rev string
--- @param context integer
--- @param diff_opts {algorithm:string, linematch:integer, layer?:gitview.Layer}
---        `layer` is for a mixed source alone, and defaults to both
--- @return gitview.View? view nil when nothing differs
--- @return gitview.LeftOut left_out
function M.build(sources, rev, context, diff_opts)
  local lines, files, hunk_rows, file_rows = {}, {}, {}, {}
  local left_out = { unchanged = {}, unmarked = {} } --- @type gitview.LeftOut
  -- A third version is what makes a view mixed, so the sources say so and the
  -- caller has nothing to add afterwards.
  local is_mixed = false

  for _, src in ipairs(sources) do
    local flines, fhunks
    if src.conflicted then
      flines, fhunks = conflict.build(src.new_lines, context)
    elseif src.index_lines then
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
      table.insert(src.conflicted and left_out.unmarked or left_out.unchanged, src.label)
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
        conflicts = src.conflicted and #fhunks or nil,
        old_rev = src.old_rev,
        new_rev = src.new_rev,
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
    return nil, left_out
  end
  return {
    lines = lines,
    files = files,
    hunk_rows = hunk_rows,
    file_rows = file_rows,
    rev = rev,
    mixed = is_mixed or nil,
    layer = is_mixed and diff_opts.layer ~= 'both' and diff_opts.layer or nil,
  }, left_out
end

--- Who wrote a commit and how long ago, short enough to share a line with the
--- commit's size.
--- @param commit gitview.Commit
--- @return string
local function byline(commit)
  return ('%s · %s'):format(commit.author, commit.when)
end

--- The lines that introduce a commit: its subject, who wrote it and when, the
--- body, and the stat. Blank lines part them, and the body's own blank lines are
--- kept as written.
--- @param detail gitview.CommitDetail
--- @param commit gitview.Commit the same commit as listed, for the byline
--- @return gitview.Line[]
function M.commit_header(detail, commit)
  local out = {}
  local function add(text, kind)
    out[#out + 1] = { text = text, kind = kind }
  end
  add(detail.message[1] or '', 'subject')
  add(('%s   %s'):format(detail.author, detail.date), 'author')
  out[2].byline = byline(commit)

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
    {
      text = ('%s   %s'):format(commit.author, commit.when),
      kind = 'author',
      byline = byline(commit),
    },
  }
end

--- A view of `lines` alone, which belong to no file.
--- @param rev string
--- @param lines gitview.Line[]
--- @return gitview.View
local function empty_view(rev, lines)
  return { lines = lines, files = {}, hunk_rows = {}, file_rows = {}, rev = rev }
end

--- Put `lines` above everything a view shows, and shift every row it keeps.
---
--- A blank line parts them from the first file, as one parts two files.
--- @param view gitview.View
--- @param lines gitview.Line[]
local function put_above(view, lines)
  local shift = #lines + 1
  local top = vim.list_extend({}, lines)
  top[#top + 1] = { text = '', kind = 'blank' }
  view.lines = vim.list_extend(top, view.lines)
  for i, r in ipairs(view.hunk_rows) do
    view.hunk_rows[i] = r + shift
  end
  for i, r in ipairs(view.file_rows) do
    view.file_rows[i] = r + shift
  end
  for _, f in ipairs(view.files) do
    f.row = f.row + shift
  end
end

--- A view of nothing yet: one line saying why, under a header when there is
--- one. Being a view rather than a notice, it keeps the header's fold for the
--- view that replaces it.
--- @param rev string
--- @param text string
--- @param header gitview.Line[]?
--- @return gitview.View
function M.placeholder(rev, text, header)
  local view = empty_view(rev, { { text = text, kind = 'notice' } })
  if header then
    M.prepend(view, header)
  end
  return view
end

--- Put a header above everything a view shows.
---
--- The blank line that parts it from what follows is not part of the header:
--- it stays in view while the header is folded.
--- @param view gitview.View
--- @param header gitview.Line[]
function M.prepend(view, header)
  put_above(view, header)
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

--- The files a view leaves out, a line each, and why: the binary files, the
--- unmerged ones with no conflict to show, and those with no textual
--- difference. Dropping any silently would hide a real change: a pure rename or
--- a mode change produces no hunks, a binary file has no versions that can be
--- diffed, and an unmerged file is unresolved whatever its contents.
---
--- The reasons line up in one column after the names, as the stat's bars do.
--- @param skipped gitview.Skipped
--- @param left_out gitview.LeftOut from `build`
--- @param unchanged_reason string what to call a change with nothing to show:
---        with whitespace ignored, "no textual change" would be a lie
--- @return gitview.Line[]
local function skipped_lines(skipped, left_out, unchanged_reason)
  local rows = {}
  local function add(labels, reason)
    for _, label in ipairs(labels) do
      rows[#rows + 1] = { label = label, reason = reason }
    end
  end
  add(skipped.binary, '(binary file)')
  add(left_out.unmarked, '(unresolved conflict with no markers)')
  add(left_out.unchanged, unchanged_reason)

  local width = 0
  for _, r in ipairs(rows) do
    width = math.max(width, vim.api.nvim_strwidth(r.label))
  end
  local out = {}
  for _, r in ipairs(rows) do
    local pad = (' '):rep(width - vim.api.nvim_strwidth(r.label))
    out[#out + 1] = { text = ('%s%s   %s'):format(r.label, pad, r.reason), kind = 'skipped' }
  end
  return out
end

--- List the files a view leaves out above everything it shows, parted from the
--- first file by a blank line. When there was nothing to show at all, the list
--- is the view.
---
--- A commit's header goes above the list, so `prepend` it afterwards: the list
--- is not part of the header, and stays in view while the header is folded.
--- @param view gitview.View? from `build`
--- @param rev string
--- @param skipped gitview.Skipped
--- @param left_out gitview.LeftOut from `build`
--- @param unchanged_reason string see `skipped_lines`
--- @return gitview.View? view nil when there is neither a file nor a skipped one
function M.list_skipped(view, rev, skipped, left_out, unchanged_reason)
  local lines = skipped_lines(skipped, left_out, unchanged_reason)
  if #lines == 0 then
    return view
  end
  if not view then
    return empty_view(rev, lines)
  end
  put_above(view, lines)
  return view
end

return M
