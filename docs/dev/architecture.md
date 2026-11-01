# Architecture

A map for reading the code, for anyone changing the plugin: its parts, the rules
they share, and what is known to be missing. What the plugin does for a user is in
[usage.md](../usage.md).

## Premises

Two premises hold up the design:

- **A diff buffer is not valid source code.** It interleaves two versions of a
  file, so no parser can highlight it. Highlights are collected from scratch
  buffers holding each whole version, and replayed as extmarks.
- **A diff buffer's text is source and nothing else.** Line numbers, markers and
  separators are drawn rather than written, so that a yank gives code. Putting
  non-source characters into the buffer is a regression, not a style choice.

The sidebar follows the second as well: a row is a path, or a sha and a subject, and
everything around it is drawn or concealed.

## Parts

| part                            | responsibility                                |
| ------------------------------- | --------------------------------------------- |
| `init`, `command`, `config`     | The entry points and the configuration        |
| `actions`, `keymaps`            | What keys can do, and which keys do it        |
| `ui/session`                    | One tab page's state, and redrawing it        |
| `ui/list`, `tree`               | A sidebar pane and its rows                   |
| `diff/`                         | Turning versions of files into a drawn view   |
| `git`, `status`                 | Every subprocess, and what is uncommitted     |
| `stage`, `index`                | Writing to the index; see [staging](staging.md) |
| `review`                        | Which files of a review are checked off       |
| `util`, `perf`                  | Helpers, and timing; see [performance](performance.md) |

The dependencies run one way:

- **Nothing under `diff/` knows `ui/` exists.**
- **`diff/source` alone reads git and the editor for a view.** It hands the rest of
  `diff/` plain data, so assembling a view looks nothing up for itself.
- **`actions` requires the session only once called**, so that a user's configuration
  can require it without loading the rest. Every key calls an action, so that a user
  can map the same functions.

## How a view is made

For each file:

1. Read the versions to compare.
2. Diff them into a flat list of rows.
3. Load each whole version into a scratch buffer, so that the highlighter sees full
   context rather than a fragment.

Then once for the view: collect highlights for the rows shown, draw the text and replay
the highlights, and discard the scratch buffers. Tree-sitter and legacy `:syntax` both
produce the same thing, and nothing downstream knows which ran.

Three shapes of view replace step 2:

- **Two versions**, for anything committed. Everything downstream takes a range, an old
  revision and a new one, rather than a commit. Which parent a commit is compared with
  is decided in one place.
- **Three versions**, for an uncommitted file: the mixed view. See [below](#the-mixed-view).
- **One version**, for an unmerged file. Its index has no stage 0, so there is no middle
  for a mixed view, and the working tree is what is left to resolve.

### The mixed view

The mixed view diffs HEAD to the index and the index to the working tree. Both diffs share
the index as one side, so every index line is placed by both at once. This is what the rest
relies on:

- **Every row knows where it sits in the index**, which is all that writing back needs.
- **Pairing lines for word diffs stays within one stage.** Across stages it would compare
  HEAD with the working tree, past the index.
- **One layer alone is a projection of these rows**, not a second diff. Building the two-way
  diff directly would give a second path for writing to the index and for finding a row's
  line.

### Rows and folds

- **Not every row stands for a line of a version.** File headers, separators, a commit's
  header and the list of files left out are buffer text too, so that they can be searched and
  yanked. Anything that looks a row up in a version has to check its kind first.
- **Every line of every version is in the buffer.** Unchanged lines are folded rather than
  dropped, so a view's row count follows the size of its files rather than of its diff; see
  [performance](performance.md#folded-rows).
- **Folds are an expression reading the view**, since manual folds would be lost whenever the
  lines are replaced.

## The session

A session is one tab page. It is registered against the tab page and dropped when that closes,
however it closes.

### Panes

- **Two list panes rather than two sections of one**, so that a long working tree does not push
  the history off the screen, and each pane carries only the keys that mean something in it.
  What this costs is that neither cursor moves when the focus does, so entering a pane is what
  tells the diff which list it follows.
- **One buffer for the diff, for the life of the session.** A buffer per file would fire the
  `Buf*` autocommands and disturb the alternate buffer and the jumplist on every cursor movement.
  The pane therefore goes back to its start when what it shows changes, and stays put otherwise.
- **What the pane shows is compared by what it names**: a kind and a path or sha. A list index
  will not do, since a refresh can move a file, and one new commit moves every commit below it.

### Changing the index

After a change everything is rebuilt from git rather than adjusted in place, since the status
letters, the file's versions and which lines count as staged all move together.

The status is read in the background, so the panes show the old index until the read catches up.
Staging from them meanwhile would write that old state back, so the session refuses to stage until
a read has drawn the result.

### Refreshing

A session re-reads the repository on `R`, after changing the index itself, when its tab page is
entered, and when a poll sees the index written. Polls on the upstream's ref and on the config
re-read only the upstream.

The line none of it may cross is changing what the diff pane shows, since nothing the user did would
account for it:

- **A diff the selection cannot have changed is kept.** A commit or range is named by sha, and a file
  by a path the working tree moves under.
- **A list that no longer names the selected commit is held back** until the cursor leaves that
  commit, since the selection follows the row and another commit would take it.
- **The files pane is allowed to drift.** A file that left the list has nothing left to show.
- **A refresh during a visual selection is dropped**, as it would take away the lines about to be
  staged. Finishing that command re-reads anyway.

### Reviews and ranges

- **A review's ends are fixed by sha when it starts**, or what is committed meanwhile would leave it.
- **The same range can be both reviewed and looked into**, so which list a row is in is part of what
  the diff pane shows and of the key a cursor position is kept under.
- **A check records what was read, not that something was.** A file that changed is told apart by a
  hash of what the view showed. Nothing is skipped by modification time, since a change missed would
  leave unread content marked as read.
- **A range ending at the working tree is read against a copy of the index** with the untracked files
  added, so that git treats them as any other file. The real index is never written for it.

## Invariants

Each of these is guarded by a test. Breaking one is a regression even if everything still looks right.

- Buffer text equals source text, row for row.
- Hunk boundaries match `git diff`.
- No line is emitted twice, and line numbers only increase.
- Highlight ranges stay inside their line and on character boundaries.
- Restricting collection to some rows does not change what those rows get.
- Colors work without `setup()` ever being called.
- Word-level pairing never crosses a file or a stage boundary.
- Unstaging a rename leaves the index equal to HEAD.
- An unmerged path is never written to the index.
- A separator outside an open conflict is not a marker, and a conflict's markers get no syntax.
- A merge is compared with its first parent only when shown alone.
- A range across a fork is compared, and said to be across one.
- A commit's view reads neither side from the working tree.
- Nothing is staged while a commit or one of its files is selected.
- The diff pane restarts at the top unless it is redrawing the same thing.
- Staging every unstaged row leaves nothing unstaged.
- Rows are never written to the index while whitespace is ignored.
- Unchanged lines are folded, never dropped, and an opened fold stays open while the same file is
  redrawn.
- A module a window option can reach through `require` holds no large table; see
  [performance](performance.md#keep-module-state-off-what-vlua-converts).

## Deliberate omissions

Alternatives a reader might reach for, and why they are not used:

- **Parsing `git diff` output instead of using `vim.diff`.** Every version is already in memory as
  lines for highlighting, and `vim.diff` agrees with git on hunk boundaries once `linematch` is off,
  so a parser would add a representation nothing else needs.
- **`linematch` on by default.** It disagrees with `git diff`, and word-level pairing does not need it.
- **`git apply --cached`.** See [staging](staging.md#why-not-a-patch).
- **`FocusGained` as a refresh trigger, and a watcher on the working tree.** See the comments on the
  session's watchers.

## Known gaps

### A conflict is shown, not merged

The conflict view shows the working tree and leaves resolving it to editing the file. Everything else a
conflict could use is in the index already, as merge stages 1, 2 and 3, and none of it is read yet.

#### Syntax from each stage

The syntax collected from the working tree breaks around a conflict, since the file with its markers is
not valid code. Each stage is valid: `:2:path` is ours, `:3:path` theirs and `:1:path` the base. Their
syntax would color each row correctly:

- Diff the working tree with each stage, and map its rows through the hunks.
- An ours row takes the matching row of `:2`, a theirs row that of `:3`, and a base row that of `:1`.
- A row outside every conflict takes `:2` or `:3`, whichever has it: a line merged in cleanly from theirs
  is only in `:3`.
- A row in no stage, such as one edited since the merge, keeps the working tree's syntax. A marker gets
  none.

It costs, per conflicted file, two or three more blobs read, two diffs and two or three more scratch
buffers parsed.

#### Keys that resolve

There is no taking ours, theirs or both from the view. A mixed view is the wrong shape for such keys, for
two independent reasons.

- **There is no staged layer to show.** A path has either stage 0 or stages 1–3, never both: `git add` on
  an unmerged path is what collapses the stages into stage 0, so resolving and staging are the same act.
- **The three versions fork rather than chain.** `HEAD -> index -> work` is a chain, and which versions
  hold a line maps onto staged and unstaged. `ours <- base -> theirs` has one common ancestor, and the same
  fact maps onto ours, theirs and both. git draws its own distinction here: `git diff` on an unmerged path
  emits a combined diff rather than an ordinary one.

Aligning two versions through a hunk list carries over as it is. Merging the two diffs does not: the mixed
view pivots on the new side of one diff and the old side of the other, while a merge pivots on base, the old
side of both.

#### The exact status pair

git tells seven pairs apart — `UU`, `AA`, `DU`, `UD`, `AU`, `UA`, `DD` — by which stages the index holds:
`AA` has no base, `DU` no ours, `UD` no theirs. Only the fact that a path is unmerged is recorded, so every
conflict is listed as `UU`. Reading `git ls-files -u` gives the pair, and the stages that syntax from each
stage needs, so both are one piece of work.

### What the working tree does not report

Two kinds of change are left to `R` while the tab page stays current: a file written by something that never
went through git, and a command that moves HEAD without writing the index. A repository whose refs are a
reftable has no file to watch, so moves of its upstream are also left to `R`.
