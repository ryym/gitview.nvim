--- Writing part of a file's changes into the git index.
---
--- No patch is produced anywhere here. The rest of the plugin never generates
--- unified diff text: it reads blobs into line arrays and hands them to
--- `vim.diff`. The index is written the same way it is read — the new contents
--- are assembled as lines, hashed, and the index entry pointed at the result.
--- That keeps the concepts already in the pipeline and nothing else, and it
--- cannot be rejected the way applying a patch can: there is no context to
--- match, so there is no `--unidiff-zero` and no failure mode to report.
local git = require('unidiff.git')

local M = {}

--- What the index records for a file no filter has anything to say about.
local DEFAULT_MODE = '100644'
local EXEC_MODE = '100755'

--- Which layers of a mixed view each operation moves.
---
--- Every changed row says which layer it belongs to, and that is the whole test.
--- An `index` row is a line the index has and neither HEAD nor the working tree
--- does, so it is a staged addition and an unstaged deletion at once; either
--- direction takes it out of the index, which is why it belongs to both.
local MOVES = {
  stage = { unstaged = true, index = true },
  unstage = { staged = true, index = true },
}

--- The rows of a stage or unstage, out of the rows on display.
---
--- Rows come back in display order, which is what keeps several insertions at
--- one index position in the order they are read on screen.
---
--- @param lines unidiff.Line[] the view's rows
--- @param first integer 1-based row
--- @param last integer 1-based row, inclusive
--- @param op 'stage'|'unstage'
--- @return unidiff.Line[]
function M.selection(lines, first, last, op)
  local moves = MOVES[op]
  local out = {}
  for row = math.max(first, 1), math.min(last, #lines) do
    local l = lines[row]
    if l.stage and moves[l.stage] and l.index_pos then
      out[#out + 1] = l
    end
  end
  return out
end

--- The rows of the change the cursor is in.
---
--- A hunk of a mixed view is a run of added and deleted rows: `mixed.trim` marks
--- one wherever such a run begins, and a run is bounded by context, by a gap, or
--- by the end of the file's rows. Walking out from the cursor finds the same run
--- without having to match a row against `hunk_rows` and guess where it ends.
---
--- @param lines unidiff.Line[]
--- @param row integer 1-based
--- @return integer? first nil when the cursor is not on a changed row
--- @return integer? last
function M.hunk_at(lines, row)
  local function changed(i)
    local l = lines[i]
    return l ~= nil and (l.kind == 'add' or l.kind == 'del')
  end
  if not changed(row) then
    return nil
  end
  local first, last = row, row
  while changed(first - 1) do
    first = first - 1
  end
  while changed(last + 1) do
    last = last + 1
  end
  return first, last
end

--- The index contents a set of rows implies.
---
--- `side` is the entire rule. A row read from the index is a line the operation
--- takes out of it; any other row is a line it puts in, in front of the index
--- line at `index_pos`. Which of the five shapes a mixed view can produce the
--- row is does not have to be known:
---
--- | row                     | `side`  | effect                        |
--- | ----------------------- | ------- | ----------------------------- |
--- | unstaged addition       | `new`   | insert before `index_pos`     |
--- | unstaged deletion       | `index` | drop that index line          |
--- | staged addition         | `index` | drop that index line          |
--- | staged deletion         | `old`   | insert before `index_pos`     |
--- | in the index only       | `index` | drop that index line          |
---
--- Positions are read off the rows rather than walked, so rows at the same
--- position cannot shift each other and the order they are applied in does not
--- matter. Only the order of insertions at one position does, and that is the
--- order they are given in.
---
--- @param index_lines string[] the index as it stands
--- @param rows unidiff.Line[] in display order
--- @return string[] lines
function M.apply(index_lines, rows)
  local insert, drop = {}, {}
  for _, l in ipairs(rows) do
    if l.side == 'index' then
      drop[l.index_pos] = true
    else
      insert[l.index_pos] = insert[l.index_pos] or {}
      table.insert(insert[l.index_pos], l.text)
    end
  end

  local out = {}
  -- One position past the end holds whatever was appended to the file.
  for p = 1, #index_lines + 1 do
    for _, text in ipairs(insert[p] or {}) do
      out[#out + 1] = text
    end
    if p <= #index_lines and not drop[p] then
      out[#out + 1] = index_lines[p]
    end
  end
  return out
end

--- Whether contents of no lines mean the index should hold no entry at all.
---
--- An empty blob and a file that is not there are the same thing to this
--- pipeline: reading either gives no lines. They are told apart by the version
--- the operation moves toward — the working tree for a stage, HEAD for an
--- unstage. If that side has no file either, the entry goes; if it has an empty
--- one, an empty blob is what belongs in the index.
---
--- @param op 'stage'|'unstage'
--- @param entry unidiff.StatusEntry
--- @param root string
--- @return boolean
local function drops_entry(op, entry, root)
  if op == 'unstage' then
    return entry.head_path == nil
  end
  return vim.fn.filereadable(vim.fs.joinpath(root, entry.path)) == 0
end

--- The mode to record for a path the index has no entry for yet. git keeps only
--- the owner execute bit of what the file system says.
--- @param path string absolute
--- @return string
local function mode_from_disk(path)
  local st = vim.uv.fs_stat(path)
  if st and bit.band(st.mode, 0x40) ~= 0 then
    return EXEC_MODE
  end
  return DEFAULT_MODE
end

--- Make `lines` the index contents for a file.
---
--- @param op 'stage'|'unstage' which direction this came from; see `drops_entry`
--- @param entry unidiff.StatusEntry
--- @param lines string[] the new index contents
--- @param root string repository root
--- @return unidiff.GitError? err
function M.write(op, entry, lines, root)
  local path = entry.path
  if #lines == 0 and drops_entry(op, entry, root) then
    local err = git.remove_index_entry(path, root)
    if err then
      return { what = 'git update-index --force-remove', stderr = err }
    end
    return nil
  end

  -- Carrying the mode over matters for an executable file; a path the index does
  -- not hold yet has none to carry, so the working tree decides.
  local mode = git.index_mode(path, root) or mode_from_disk(vim.fs.joinpath(root, path))
  local content = #lines == 0 and '' or table.concat(lines, '\n') .. '\n'
  local sha, hash_err = git.hash_object(path, content, root)
  if not sha then
    return { what = 'git hash-object', stderr = hash_err or '' }
  end
  local err = git.update_index(mode, sha, path, root)
  if err then
    return { what = 'git update-index', stderr = err }
  end
  return nil
end

return M
