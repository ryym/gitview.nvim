# Staging, and how the index is written

Staging part of a file here does not go through a patch. The new index contents
are assembled as lines, written as a blob with `git hash-object`, and the index
entry pointed at it with `git update-index`. That is unusual enough — most tools
generate a patch and run `git apply --cached` — that this document exists to say
what those commands do, why they were chosen, and where the approach has holes.

Everything below was checked against git 2.55. `..` in an output sample means a
truncated hash.

## The index is a table of blobs

Read the index as it really is:

```
$ git ls-files -s
100644 de980441c3ab03a8c07dda1ad27b8a11f39deb1e 0	f.txt
└mode  └blob hash                               └stage └path
```

Two facts about git's object model make the rest follow.

- **A blob is content and nothing else.** No name, no history, no position. Its
  hash is computed from the content, so identical content is always the same
  blob.
- **The index is a list of entries**, each pairing a path with a blob hash and a
  mode.

So **staging a file is pointing its index entry at a different blob**. Nothing
more happens. `git add` is a wrapper over exactly that: `hash-object` and
`update-index` predate it and are what it was built from.

The commands worth knowing when looking at any of this:

| command                | what it shows                                 |
| ---------------------- | --------------------------------------------- |
| `git ls-files -s`      | the index, raw: mode, hash, stage, path        |
| `git ls-files -u`      | only the unmerged entries of a conflict        |
| `git cat-file -p <sha>` | an object's contents                          |
| `git cat-file -t <sha>` | its type: blob, tree or commit                |
| `git show :path`       | that path as the index has it                 |
| `git show HEAD:path`   | that path as HEAD has it                      |

`:path` and `HEAD:path` are the same specs `diff/source.lua` reads the three
versions with.

## Whole files: which command, and two traps

A whole file needs no plumbing. `stage.lua` picks a porcelain command and runs
it, and the only interesting part is what it has to branch on.

`git add -- <path>` covers staging every case. Since git 2.0 it stages a deletion
as well as content, so a modification, an addition, a deletion and an untracked
file all take the same command.

Unstaging is not its mirror image. It branches twice:

### A staged rename takes both of its names

`git restore --staged -- <new>` restores the new path and leaves the old one
still deleted in the index — a state the file never had:

```
$ git status --short        # after `git mv old.txt new.txt`
R  old.txt -> new.txt
$ git restore --staged -- new.txt
$ git status --short
D  old.txt                 # the deletion is still staged
?? new.txt
```

Passing both names restores the whole rename. `StatusEntry` carries `head_path`
alongside `path` for this.

### Before the first commit there is nothing to restore from

`git restore --staged` needs HEAD, so with no commit yet the entry has to leave
the index instead:

```
git rm --cached -f -q -- <path>
```

- `--cached` leaves the working tree alone: the file becomes untracked.
- `-f` is **not optional.** git refuses to drop an entry whose content matches
  neither the file nor HEAD, and with no HEAD that is every staged file that was
  then edited again (`AM`).

The condition is the repository's, not the file's, so the session asks
`git rev-parse --verify --quiet HEAD` alongside the commit list and keeps the
answer.

## Part of a file: two plumbing commands

### 1. Write the contents as a blob

```
$ printf 'a\nb\nc\nd\n' | git hash-object -w --path f.txt --stdin
d68dd4031d2ad5b7a3829ad7df6635e27a7daa22
```

- `-w` writes the object; without it the hash is only computed.
- `--path` tells git which path's filters to apply, so a file under a clean
  filter — CRLF conversion, git-lfs — is stored the way a real checkout of that
  path would store it. Leaving it out stores the working-tree form and the index
  then disagrees with what `git add` does.

Nothing is staged yet. An object has been placed in the database and nothing
refers to it, so a failure at this point leaves nothing to undo: an unreferenced
blob is collected by `git gc`.

### 2. Point the entry at it

```
$ git update-index --add --cacheinfo 100644,d68dd40..,f.txt
$ git ls-files -s
100644 d68dd4031d2ad5b7a3829ad7df6635e27a7daa22 0	f.txt
```

- `--add` allows a path the index does not hold yet, which is how the first
  lines of an untracked file get staged.
- The mode has to be supplied. It is carried over from `git ls-files -s`, or
  taken from the working tree's owner execute bit when there is no entry yet.
- `--cacheinfo` reads none of the object's contents and never touches the working
  tree.

The result is a partially staged file:

```
$ git status --short
MM f.txt
$ git diff --cached --stat     # HEAD -> index
 f.txt | 1 +
$ git diff --stat              # index -> working tree
 f.txt | 2 +-
```

### Removing an entry

```
git update-index --force-remove -- <path>
```

`--force-remove` is the only form that works while the working tree still has the
file; plain `--remove` keeps the entry in that case.

## What decides the new contents

`index.lua` builds the new contents from the rows on display. Every row of a
mixed view carries `index_pos`, its position in the index, so an operation is
stated entirely in index coordinates and `side` says what to do:

| row               | `side`  | effect                    |
| ----------------- | ------- | ------------------------- |
| unstaged addition | `new`   | insert before `index_pos` |
| unstaged deletion | `index` | drop that index line      |
| staged addition   | `index` | drop that index line      |
| staged deletion   | `old`   | insert before `index_pos` |
| in the index only | `index` | drop that index line      |

A row read from the index is a line the operation takes out; any other row is one
it puts in. Which of the five shapes a row is never has to be established.

Positions are read off the rows rather than walked, so rows at the same position
cannot shift each other and a selection applies in any order. Only the order of
insertions at one position matters, and rows are collected in display order for
that.

Which rows an operation moves comes from the row's `stage`:

- `s` takes the `unstaged` layer.
- `u` takes the `staged` layer.
- An `index` row — a line the index has that neither HEAD nor the working tree
  does — belongs to both, since either direction removes it from the index.

### The index contents are kept

`index.apply` writes the chosen rows into the index contents as they stand, so
the session keeps the selected file's `index_lines` for as long as it shows that
file's diff.

## Why not `git apply --cached`

Generating a patch and applying it to the index is the usual approach, and it
works:

```
$ cat p.diff
--- a/f.txt
+++ b/f.txt
@@ -3,0 +4 @@
+d
$ git apply --cached --unidiff-zero p.diff
```

It was not taken, for two reasons.

### It would add the one representation this codebase does not have

The pipeline never generates unified diff text. It reads blobs into line arrays
and hands them to `vim.diff` with `result_type = 'indices'`; there is no patch
writer anywhere. Assembling the new contents uses `index_lines` and `index_pos`,
which already exist, and introduces no new concept.

### A patch can be rejected; contents cannot

`git apply` matches the patch's context against what it is applying to, and
refuses when it does not agree:

```
$ git apply --cached bad.diff
error: patch failed: f.txt:1
error: f.txt: patch does not apply
```

This is what `--unidiff-zero` exists to work around: patches are generated with
no context at all, and `git apply` is told to accept a form it otherwise treats
as unsafe. Writing the finished contents has no context to match, so there is no
rejection to report and no failure mode to design around.

The difference is that git is told the **result** rather than a **change**.

## Resolved ambiguities

### Contents of no lines

An empty blob and an absent file read the same here: both give no lines, because
`git.blob_lines` maps an empty blob to `{}`. They are told apart by the version
the operation moves toward — the working tree for a stage, HEAD for an unstage:

- that side has no file either → drop the entry with `--force-remove`
- that side has an empty file → write an empty blob

Without this, unstaging all of a newly added file would report a staged empty
file plus unstaged additions, rather than an untracked file.

### The final newline

Contents are written as `table.concat(lines, '\n') .. '\n'`, so **a file with no
trailing newline gains one when part of it is staged.** Nothing in the pipeline
can represent a missing final newline: a blob is read as a line array and written
back as one.

Fixing it means carrying a flag on `Source` for whether each version ended with a
newline, and honouring it here.

## Hazards and gaps

### Merge conflicts are not written to

A conflicted path has three index entries rather than one:

```
$ git ls-files -s
100644 df967b9.. 1	f.txt     # stage 1: merge base
100644 351be5b.. 2	f.txt     # stage 2: ours
100644 e45c9c2.. 3	f.txt     # stage 3: theirs
```

There is no stage 0, which is the only stage anything here can read a version
from: `git show :f.txt` fails with `path 'f.txt' is in the index, but not at
stage 0`, and `cat-file --batch` answers `missing`.

Writing a stage-0 entry over those three reports no error and drops all of them:

```
$ git update-index --add --cacheinfo 100644,<sha>,f.txt
$ git status --short
MM f.txt                       # no longer UU: the conflict is "resolved"
```

`git restore --staged` does the same thing by another route — it succeeds and
leaves ` M`, with the conflict neither resolved nor still recorded.

So an unmerged path is recognised and nothing writes to its index entry. Its
view is the working tree with its conflict markers, described in
[architecture.md](architecture.md#conflict-view), and none of its rows is a
change that could be staged.

What holds today:

- `status.entries` sets `conflicted` from the `U` status letter, which
  `git diff --diff-filter` documents as "unmerged". Both listings report it, and
  `status.in_index` is false because there is no stage 0.
- The row-level keys refuse it and say why. The view has no `index_lines` to
  write rows into, so `apply_to_rows` checks the flag before anything else,
  where it would otherwise end without a word. `S` and `U` check it too, since
  no row of the view is a change for them to find.
- Whole-file `u` is refused, because `git restore --staged` would discard the
  merge.
- **Whole-file `s` is allowed.** `git add` on an unmerged path marks the conflict
  resolved, which is how git itself is told that the working tree holds the
  answer. It is the one operation with a sensible reading.

git tells seven pairs apart — `UU`, `AA`, `DU`, `UD`, `AU`, `UA`, `DD` — by which
of the three stages the index holds. Only the fact that the path is unmerged is
recorded, so all of them are listed as `UU`; see
[architecture.md](architecture.md#the-exact-status-pair).

### Ignoring whitespace and the rows disagree

`:GitView` can be told to stop counting lines that differ only in
whitespace as changed. A line folded away by that is drawn as a `context` row,
and a mixed view reads context from the index — so the row shows the index
version while the working tree holds another.

Writing the shown rows back would then leave that line at its index version, and
the view, still ignoring whitespace, would go on showing nothing unstaged while
`git status` reported the file as modified. Measured, with HEAD and the index at
`a b c` and the working tree at `a "  b  " C`:

| | index after staging every unstaged row |
| --- | --- |
| counting whitespace | `a` `  b  ` `C` — equals the working tree |
| ignoring it | `a` `b` `C` — does not |

So the row-level keys refuse while it is on. Whole-file `s` and `u` are
unaffected, because they are porcelain commands that read no rows: `git add`
takes the file as it is on disk, whitespace included. That is the same line drawn
for an unmerged path, and for the same reason — the rows on display are not a
faithful statement of the file.

Comparing two alignments, one ignoring whitespace for display and one counting it
for the index, would lift this. They do not correspond row for row, so it is not
a small change.

### Modes other than a regular file

`mode_from_disk` only ever answers `100644` or `100755`. A symlink (`120000`) or
a submodule (`160000`) already in the index keeps its mode, because that comes
from `git ls-files -s`, but an untracked one would be staged as a regular file.
Staging part of either is meaningless, so they belong with the cases that are
listed and refused.

### Unverified

- **`assume-unchanged` and `skip-worktree`.** Whether `--cacheinfo` preserves
  these bits has not been measured. It matters for sparse checkouts.
- **`git add -N` (intent-to-add).** `--cacheinfo` turns such an entry into an
  ordinary addition, which is probably what is wanted, but it is untested.

## On depending on plumbing at all

The concern that git's internals may change does not really apply, because
nothing here reads or writes them. Objects are not compressed by hand and
`.git/index` is not parsed; git is asked to do both through its CLI. The index
file format has been revised several times — v2 through v4, sparse index,
untracked cache — while `ls-files -s` and `update-index` kept their interface,
which is the whole point of the split git maintains:

- **porcelain** (`git status`, `git log`) is for people, and its output may change
  without notice.
- **plumbing** (`hash-object`, `update-index`, `cat-file`, `ls-files`) is for
  programs, and its interface is kept stable.

Hash-agnosticism comes free: the hash `hash-object` returns is passed to
`--cacheinfo` unread, and nothing assumes its length or alphabet, so a repository
using SHA-256 needs no change.

The more fragile dependency in this codebase is the other direction. The two
status letters are assembled to match `git status --short`, which is porcelain
and carries no such promise — though they are only displayed, never branched on.

### If it ever has to change

The line arithmetic is independent of how the result is written.
`index.selection`, `index.apply` and `index.hunk_at` decide which rows move and
what the contents become, and know nothing about blobs. Switching to patches
would replace `index.write` and the four functions in `git.lua` that call this
plumbing, and leave the rest alone.
