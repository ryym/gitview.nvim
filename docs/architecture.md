# Architecture

## Modules

The unified diff is one part of the plugin rather than the whole of it, so its
pipeline lives under `diff/` and the modules every part needs sit above it.

| module               | responsibility                                          |
| -------------------- | ------------------------------------------------------- |
| `init.lua`           | Commands and the public API                             |
| `config.lua`         | Defaults, and resolving a call's options against them   |
| `git.lua`            | Every subprocess call, and the parsers for their output |
| `status.lua`         | What is uncommitted, as one entry per file               |
| `stage.lua`          | Which git command moves a file into or out of the index  |
| `index.lua`          | Writing part of a file's changes into the index          |
| `util.lua`           | Messages shown to the user                              |
| `diff/source.lua`    | Reading the versions to compare, and their filetype     |
| `diff/view.lua`      | Assembling sources into a view, and freeing it           |
| `diff/lines.lua`     | `vim.diff` wrapper, unified line list, del/add pairing  |
| `diff/mixed.lua`     | Merging HEAD, index and working tree into one line list |
| `diff/highlight.lua` | Scratch buffers, and collecting highlight segments      |
| `diff/worddiff.lua`  | Word-level ranges within a pair of changed lines        |
| `diff/render.lua`    | Building the buffer, extmarks, gutter, winbar           |
| `diff/keymap.lua`    | What the keys do inside a diff buffer                   |
| `ui/list.lua`        | The file list: its rows, its gutter, its winbar          |
| `ui/session.lua`     | One tab page's state, and redrawing it                   |

The dependency direction is one-way: `init` uses everything, `source` uses
`status`, `stage` uses `status` and `git`, `index` uses `git`, `status` uses
`git`, `view` uses `lines`, `mixed` and `highlight`, `render` uses `highlight`,
`worddiff` and `lines`, and `config`, `util` and `git` depend on nothing but
Neovim.

`ui` uses `status` and, once it shows diffs, the pipeline under `diff/`; nothing
under `diff/` knows that `ui` exists.

`source` is the only part that reads git and the editor. It hands `view` plain
data, so assembling a view looks nothing up for itself.

## The file list

`:UnidiffStatus` opens a tab page that outlives the moment it was opened in.
That is the difference from the diff commands: those render a snapshot and
forget it, while a session keeps its repository root, its entries and the tail
of the history so that all of them can be re-read.

A session is registered against its tab page and dropped when that tab closes,
however it closes. Its three buffers go with it.

The list follows the same rule as a diff buffer: the text is the thing itself,
and everything around it is drawn. A row is a path, or a sha and a subject, and
nothing more, so yanking one gives something that names the thing elsewhere; the
status letters are painted by `'statuscolumn'`, and what the pane is holding by
`'winbar'`.

A row stands for a `unidiff.ListTarget` — a kind and an index — rather than for
an entry, because a row is no longer always a file: it can be a commit, or a file
of one. A row can also stand for nothing, which is what the notices are. The
mapping is kept in both directions: the cursor picks a target, but `]f` picks a
file from inside the diff.

What a pane draws is a `unidiff.ListModel` rather than a list of entries, and the
session hands each pane a fresh one on every redraw. The gutter is computed while
those rows are built rather than when the screen line is drawn: an entry has two
status letters, a commit's file has one and a commit has none, and putting that
decision in `'statuscolumn'` would mean teaching it every kind of row there is.

#### Two panes, not two sections

The sidebar is split: the uncommitted files above, the commits below, each its
own window and its own buffer. One buffer holding both would push the history off
the bottom of the screen as soon as a working tree had more changes than the
sidebar is tall — and the history is the part that does not grow.

Being separate windows is what makes the rest simple:

- **`list.state` is keyed by buffer**, so `'statuscolumn'` and `'winbar'` already
  read the pane they are drawn in. Telling the two apart needed nothing but a
  `pane` field for the winbar to switch on.
- **Each pane carries only the keys that mean something in it**, instead of one
  set of keys branching on the kind of row under the cursor. `s` and `u` are the
  exception: the commits pane maps them in order to say why they do nothing,
  since leaving `s` unmapped would let it reach a buffer that cannot be modified
  and error.
- **No row has to stand for nothing.** The section header and the blank row that
  separated the two lists are gone, and with them the rule that had to pull a
  cursor off them.

What two cursors cost is that neither moves when the focus does, so `WinEnter` is
watched alongside `CursorMoved`: entering a pane is the only thing that tells the
diff the selection now comes from that list.

The commits pane is the one with `'winfixheight'`. What the sidebar gains or
loses on a resize belongs to the files, which is the list that grows without
bound.

### The diff pane

The pane is one buffer for the life of the session, drawn into again on each
selection. Making a buffer per file and swapping it into the window would fire
the `Buf*` autocommands, disturb the alternate buffer and the jumplist, and
leave the old buffer to dispose of — on every cursor movement in the list.

What one buffer costs is that a position in it outlives the contents it belonged
to. Replacing the text only clamps the cursor to the new line count, so a short
diff drawn after a long one opens at its end. The pane is therefore put back to
its start whenever what it shows changes, and left alone whenever it does not:
staging a hunk redraws the same file, and being thrown back to the top on every
`s` would make working down a diff impossible.

Which of the two it is is decided by comparing what is shown — a kind and a path
or sha — rather than the selection itself, because a refresh can move a file to
another index while it goes on being the same file.

Each file is read as three versions and shown through `diff/mixed`, the same
view `:UnidiffMixed` uses, so the choice between staged and unstaged never has
to be made. Three things a view cannot express — a binary file, a change with no
lines, and nothing selected at all — are drawn by `render.notice`, which drops
the view along with the text so that the gutter and winbar describe nothing
rather than what was there before.

The keys shared with a standalone diff buffer mean something different here:
`q` gives up the session rather than one window, and `]f` moves the list's
cursor rather than scrolling to the next file of a combined view. `diff/keymap`
takes those three as callbacks instead of branching on where it is used.

### The commit list

The lower pane lists the most recent commits, and selecting one draws what it
changed. That view is the ordinary two-version one, the shape `:UnidiffAll`
already produces: both sides are committed, so there is no index between them
and nothing to mark as staged.

Three things follow from both sides being committed:

- **Neither side comes from the working tree.** `source.for_commit` reads both
  from the object database, in one `git cat-file --batch` as everything else
  does. The working tree is not one of the versions being compared, and may no
  longer have the file.
- **The view is marked `historical`,** and `<CR>` refuses to jump from it. Its
  line numbers name lines of the commit, so jumping would land on whatever now
  occupies that line, or on a file that is no longer there.
- **Nothing about it can be staged.** `s` and `u` refuse outright rather than
  relying on there being no index contents to write.

Building the view is deferred by a few tens of milliseconds while a commit is
selected, and a generation counter drops the result if the selection has moved
on. A commit's diff is every file it touched, so without that, sweeping the
cursor down the list would run the whole pipeline once per row passed over. A
file row costs a single file's view and is still drawn at once.

#### Which commit is compared with what

`git log -z` gives the list, including each commit's parents, which is what
decides how it can be compared at all:

| parents | compared with                              |
| ------- | ------------------------------------------ |
| none    | `git diff-tree --root`, against the empty tree |
| one     | `git diff <parent> <sha>`                  |
| several | the same, against the first parent         |

`git diff-tree -m` would have covered all three, but on a merge it concatenates
one diff per parent and `--no-commit-id` removes the headers that would tell the
blocks apart. `--first-parent` is a rev-list option that `diff-tree` rejects.
Naming the parent explicitly avoids the question, and both commands print the
same `--name-status` and `--numstat` records, so one pair of parsers reads both.

#### Looking into one commit

`<CR>` on a commit sets the session's `scope`, and the commits pane is
**replaced** by the files that commit changed. The files pane above is left
alone, so what is uncommitted stays in view. Replacing rather than merging the
two lists is what a commit's `unidiff.Change` and an uncommitted
`unidiff.StatusEntry` being different shapes — one status letter against two, a
parent against three versions — makes right.

Which commit is being looked into is named by the pane's `'winbar'`, so no row of
the buffer stands for it and every row remains a file.

- **The change list is read once, on the way in, and kept.** It is what the rows
  stand for and what each file's two versions are then read against, so
  selecting a file lists nothing again. `source.for_commit_change` reads one
  entry of it the way `source.for_entry` reads one status entry.
- **A commit is immutable, so a refresh leaves the scope alone.** What `R`
  re-reads is everything underneath, which is what backing out goes back to.
- **`<BS>` backs out**, and the cursor lands on the commit that was being looked
  into rather than wherever the row happens to fall. `q` still closes the
  session: a stack one level deep is not worth overloading it for.
- **`<CR>` inside a commit focuses the diff**, which is what it does in the files
  pane, since the row already names what is being shown.

`]f` and `[f` mean what the view is shaped like rather than where they are
pressed. A whole commit is many files in one buffer, so they scroll within it; a
single file — uncommitted or from a commit — is one of many rows, so they move
the list's cursor.

Comparing two commits with each other is not implemented. The listing and the
two-sided blob read it needs are both here; what is missing is how the second
commit is chosen.

### Changing the index

Two modules write to the index, and both hand back what they decided rather than
acting on it, so the decision can be tested without a repository:

- `stage.lua` picks the porcelain command that stages or unstages a whole file.
- `index.lua` assembles the index contents a set of diff rows implies, and writes
  them as a blob the entry is pointed at. No patch is generated anywhere.

[staging.md](staging.md) covers both in full: the commands, why `git apply
--cached` was not used, what a row's `side` decides, and where the approach has
holes. The parts that constrain the rest of the design are:

- **The session keeps the selected file's `index_lines`.** A view is trimmed, so
  everything away from a change has been folded into a `gap` row; the index
  contents cannot be read back out of the buffer.
- **Whether the repository has a HEAD is a session-level flag**, re-read on every
  refresh, because it decides which unstaging command is even available.
- **An unmerged file is listed but not drawn.** It has no stage 0 to read a
  version from, and writing one over a conflict's three entries reports no error
  and discards them. It is refused everywhere but whole-file `s`, which is
  `git add` resolving it. The view it needs is a
  [known gap](#a-merge-conflict-has-no-view).

After a change everything is rebuilt from git rather than adjusted in place: the
status letters, the file's three versions and which of its lines count as staged
all move together. The cursor follows what was selected rather than the row it
was on, by path for a file and by sha for a commit, because a file added or
committed away shifts every row below it. When the selection is gone altogether
each pane keeps the row it was on, clamped to what was just drawn.

## Pipeline

For each file in the diff:

1. **Read both versions.** The old side comes from git, the new side from the
   file's loaded buffer if it has one and from disk otherwise. git is only ever
   used to read blobs and to list what changed; the diff itself is `vim.diff`.
2. **Diff.** `lines.hunks()` returns raw hunk indices; `lines.build()` turns them
   into a flat list of context/deleted/added lines with both line numbers
   attached.
3. **Load ghost buffers.** Each whole version goes into its own scratch buffer,
   so the highlighter sees full context rather than a hunk fragment.

Then once for the whole view:

4. **Collect highlights** from the ghost buffers, for the displayed rows only.
   Tree-sitter is used when the language has a parser and legacy `:syntax`
   otherwise; both produce byte ranges paired with highlight groups, and nothing
   downstream knows which ran.
5. **Render**: write the source text, replay the highlights as extmarks, and
   layer diff backgrounds, word-level highlights, headers and separators on top.
6. **Discard the ghost buffers.** They exist only for step 4.

Step 3 is what makes a line deleted from the middle of a multi-line string come
out as a string: the fragment alone carries no such information.

## Data shapes

### `unidiff.Line`

One row of the rendered buffer.

- `text` — the source line, exactly as it appears in the buffer
- `kind` — `context`, `add` or `del`
- `old_lnum` / `new_lnum` — line numbers in each version; `nil` on the side
  where the line does not exist
- `side` — which version `text` came from, `old` or `new`
- `row` — 0-based row of `text` in that version's ghost buffer
- `file` — index into `View.files`
- `index_pos` — where the row sits in the index; a mixed view only

`side` plus `row` plus `file` is what links a rendered row back to the ghost
buffer its highlights come from. `old_lnum` / `new_lnum` are for display and for
jumping to the source; they are not used for highlighting. `index_pos` is there
for writing the index back: see `diff/mixed` for how every row is placed against
it, including the rows the index does not have.

### `unidiff.View`

Everything one diff buffer needs, stored in `render.views[bufnr]` and dropped on
`BufWipeout`.

- `lines` — the `unidiff.Line[]`, one per buffer row
- `files` — `unidiff.File[]`, each with its ghost buffers, language, label, and
  the 1-based row of its header line
- `hunk_rows` — 1-based rows to jump between with `]h` / `[h`
- `rev`, `note` — shown in the winbar

Rows in `hunk_rows` and `files` are absolute in the combined buffer. Assembling
several files means concatenating each file's lines and shifting its rows by the
running offset.

### Line kinds

Every buffer row has a `unidiff.Line`, but only some of them stand for a line of
one of the two versions:

| kind                     | text                       | has line numbers |
| ------------------------ | -------------------------- | ---------------- |
| `context`, `add`, `del`  | source text                | yes              |
| `gap`                    | `···· N unchanged lines ····` | no            |
| `file`                   | the file's label           | no               |
| `blank`                  | empty, separates two files | no               |

`dlib.source_kinds` is the test for the first group. Anything that looks a line
up in a ghost buffer, prints a gutter, or jumps to the source has to check it
first, because the other kinds carry no `side`, `row` or `file`.

A `gap` is only emitted for two or more lines. It takes a row of its own, so
folding a single line away saves nothing and loses the line.

## Layering

Everything drawn is an extmark, ordered by priority:

| priority | layer                                        |
| -------- | -------------------------------------------- |
| 10       | Added/deleted line background, with `hl_eol` |
| 100      | Replayed syntax highlighting                 |
| 200      | Word-level change highlights                 |

The ordering is the point: the line background has to sit under the syntax
colors so they survive, and the word-level highlights have to sit over both so a
changed word stands out against its own line's background.

Separators and file headers are ordinary buffer lines, highlighted by the same
whole-line range marks as the diff colors. They were virtual lines once; making
them real means they can be searched, jumped to by row, and copied along with the
lines around them, and it removes the special cases that `virt_lines` above line
1 forced (see `neovim-notes.md`).

Two things are still deliberately _not_ buffer text:

- the gutter, drawn with `'statuscolumn'`, so line numbers stay out of a yank
- the name of the file the cursor is in, drawn in the `'winbar'`

The winbar is recomputed on redraw rather than set once, so it follows the cursor
through a multi-file view and keeps naming the file after its header line has
scrolled off.

## Mixed view

`:UnidiffMixed` (`init.open_mixed`) replaces step 2 of the pipeline with
`mixed.build`, which takes three versions of each file instead of two. The rest
of the pipeline is unchanged apart from a third ghost buffer for the index.

### Aligning on the index

`mixed.merge` diffs HEAD -> index (the staged changes) and index -> working tree
(the unstaged ones). Both diffs share the index as one of their sides, so every
index line is placed by both at once. Each row then falls into one case:

| HEAD | index | work | `kind`    | `stage`    |
| ---- | ----- | ---- | --------- | ---------- |
| yes  | yes   | yes  | `context` | —          |
| yes  | —     | —    | `del`     | `staged`   |
| —    | yes   | yes  | `add`     | `staged`   |
| yes  | yes   | —    | `del`     | `unstaged` |
| —    | —     | yes  | `add`     | `unstaged` |
| —    | yes   | —    | `del`     | `index`    |

- `old_lnum` is the HEAD line number and `new_lnum` the working-tree one, as in
  an ordinary view. An `index` row has neither.
- A line in HEAD and the working tree but not the index is not a case of its
  own. It comes out as a staged deletion plus an unstaged addition.
- Rows are read from the index ghost buffer (`side = 'index'`) whenever the
  index has the line, and from HEAD or the working tree otherwise.

### Ordering between index lines

Between two index lines there can be HEAD lines the index dropped and
working-tree lines the index lacks. They are normally emitted deletions first.
The exception is when the index line above was itself removed from the working
tree. The additions then replace that line, so they come first. Otherwise a
partially staged hunk interleaves the two layers:

```
- a      (unstaged)      - a      (unstaged)
- b  S                   + A      (unstaged)
+ A      (unstaged)      - b  S
+ B  S                   + B  S
  wrong                    right
```

### Pairing

`change_pairs()` only pairs a deletion and an addition of the same `stage`.
Across stages they are two separate changes, and a word diff between them
would compare HEAD with the working tree past the index.

### File list

`status.list` names the files. A file appears when `git diff --cached`,
`git diff` or `git ls-files --others` lists it, and it appears once however
many of them do: the first two are joined on the index path, which is the only
name both use for a file renamed in the index.

Each entry keeps the status letter of either side, as `git status --short`
prints them, but nothing downstream branches on it. The diff is built from HEAD,
the index and the working tree whatever changed, and a version the file does not
have is empty — an untracked file has neither of the first two. A file with only
staged changes has a working tree equal to its index, and one with only unstaged
changes has a HEAD equal to its index, so neither is read twice.

Binary files are excluded. git flags the tracked ones through
`git diff --numstat`; it never diffs an untracked file, so those are recognised
the way git itself does it, by a NUL byte in the first 8000 bytes.

## Invariants

Each of these is guarded by a test. Breaking one is a regression even if
everything still looks right.

| invariant                                                               | guarded by                                       |
| ----------------------------------------------------------------------- | ------------------------------------------------ |
| Buffer text equals source text, row for row                             | `render_spec`, `multifile_spec`                  |
| Hunk boundaries match `git diff`                                        | `diff_spec`                                      |
| No line is emitted twice, and line numbers only increase                | `diff_spec`                                      |
| Highlight ranges stay inside their line and on character boundaries     | `render_spec`, `worddiff_spec`, `highlight_spec` |
| Restricting collection to some rows does not change what those rows get | `highlight_spec`                                 |
| Colors work without `setup()` ever being called                         | `render_spec`                                    |
| Word-level pairing never crosses a file boundary                        | `diff_spec`                                      |
| Word-level pairing never crosses a stage boundary                       | `mixed_spec`                                     |
| Unstaging a rename leaves the index equal to HEAD                       | `stage_spec`                                     |
| An unmerged path is never written to the index                           | `session_spec`                                   |
| A merge is compared with its first parent only                          | `git_spec`                                       |
| A commit's view reads neither side from the working tree                | `session_spec`                                   |
| Nothing is staged while a commit or one of its files is selected        | `session_spec`                                   |
| Looking into a commit replaces the commits pane, not the files pane      | `list_spec`, `session_spec`                      |
| The diff pane restarts at the top unless it is redrawing the same thing  | `session_spec`                                   |
| Staging every unstaged row leaves nothing unstaged                      | `index_spec`                                     |

## Deliberate omissions

Alternatives that were tried or considered and rejected, so they are not
re-attempted by accident:

- **Generating a patch and running `git apply --cached`.** See
  [staging.md](staging.md#why-not-git-apply---cached).
- **Parsing `git diff` output instead of using `vim.diff`.** Workable, and it
  would inherit the user's git configuration, but git compares the file on disk
  while this compares the buffer. `vim.diff` already agrees with git on hunk
  boundaries once `linematch` is off.
- **`linematch` on by default.** It improves word-level pairing but disagrees
  with `git diff`. It is configurable; the default favours agreement.
- **Character-level word diff.** Unrelated lines share letters, so the result
  reads as noise. Tokens are runs of word characters instead.
- **`line_hl_group` for the line background.** See [neovim-notes.md](neovim-notes.md).
- **`vim.inspect_pos()` for collecting highlights.** See the same document.

## Known gaps

### A merge conflict has no view

An unmerged file is listed and then says `(unresolved conflict)` where its diff
would be. That notice is a placeholder for a view that does not exist yet, not a
decision that a conflict has nothing worth showing. Everything it needs is in the
index already, as merge stages 1, 2 and 3.

A mixed view is the wrong shape for it, for two independent reasons.

- **There is no staged layer to show.** A path has either stage 0 or stages 1–3,
  never both: `git add` on an unmerged path is what collapses the stages into
  stage 0, so resolving and staging are the same act. The question a mixed view
  exists to answer — staged or unstaged — does not arise.
- **The three versions fork rather than chain.** `HEAD -> index -> work` is a
  chain, and which versions hold a line maps onto staged and unstaged.
  `ours <- base -> theirs` has one common ancestor, and the same fact maps onto
  ours, theirs and both. git draws its own distinction here: `git diff` on an
  unmerged path emits a combined diff, `@@@` with two marker columns, rather than
  an ordinary one.

So the display, the gutter legend, the winbar and the keys all differ — take
ours, take theirs, take both, rather than stage and unstage. It is a sibling of
the mixed view, not a setting of it.

What carries over and what does not:

- `mixed.align` is reusable as it stands. It turns a hunk list into a line
  correspondence and assumes nothing about what the two sides are.
- `mixed.merge` is not. Its pivot is the new side of one diff and the old side of
  the other, so it reads `staged.new_to_old` and `unstaged.old_to_new`. A merge
  pivots on base, which is the old side of **both** diffs. The assembly is the
  same shape written against different tables.
- **Not all three stages exist.** Each can be missing, and the status pair names
  which: `AA` has no base, `DU` no ours, `UD` no theirs. Treating a missing stage
  as empty is what the pipeline already does for a version a file does not have.

Reading `git ls-files -u` is what a merge view needs, and it also yields the
exact status pair, so the present rounding of every conflict to `UU` is resolved
by the same work.

### Word-level pairing needs equal-sized blocks

`change_pairs()` matches deleted lines to added ones by position, so a block
replaced by one of a different size gets no word-level highlights at all.
Matching them by similarity instead would lift that, and unlike enabling
`linematch` it would not move any hunk boundary: which lines are compared for
word highlights is independent of how the diff is laid out.
