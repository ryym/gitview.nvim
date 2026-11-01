# Staging

For anyone changing how the index is written: why it is done this way, the rules that
keep it safe, and where it has holes. What staging looks like to a user is in
[usage.md](../usage.md#staged-and-unstaged-in-one-view).

Staging a whole file runs a porcelain command. Staging part of one assembles the new
index contents as lines, writes them as a blob and points the index entry at it. The
reasons for each command are in the comments of `stage.lua`, `index.lua` and `git.lua`.

## Why not a patch

Most tools generate a patch and run `git apply --cached`. It was not taken, for two
reasons.

- **It would add a representation the code does not have.** The pipeline reads blobs
  into line arrays and hands them to `vim.diff`. It never generates diff text, while
  assembling new contents uses what a mixed view's rows already carry.
- **A patch can be rejected; contents cannot.** `git apply` matches a patch's context
  against what it applies to, and refuses when they disagree. Writing the finished
  contents has no context to match, so there is no such failure to design around.

The difference is that git is told the **result** rather than a **change**.

## How rows decide the contents

Every row of a mixed view carries its position in the index, so an operation is stated
entirely in index coordinates. A row read from the index is a line the operation takes
out, and any other row is one it puts in.

| row               | effect                    |
| ----------------- | ------------------------- |
| unstaged addition | insert at its position    |
| unstaged deletion | drop that index line      |
| staged addition   | drop that index line      |
| staged deletion   | insert at its position    |
| in the index only | drop that index line      |

Positions are read off the rows rather than walked, so rows at the same position cannot
shift each other and a selection applies in any order. Only the order of insertions at
one position matters, which is display order.

## When rows must not be written

Writing rows back is only safe while they state the file faithfully. Two cases fail that,
and for both the row-level keys refuse while whole-file `s` still works, since it reads no
rows.

### Merge conflicts

A conflicted path has three index entries, at stages 1 to 3, and no stage 0:

```
$ git ls-files -s
100644 df967b9.. 1	f.txt     # merge base
100644 351be5b.. 2	f.txt     # ours
100644 e45c9c2.. 3	f.txt     # theirs
```

Writing a stage-0 entry over them reports no error and drops all three. The conflict then
reads as resolved:

```
$ git update-index --add --cacheinfo 100644,<sha>,f.txt
$ git status --short
MM f.txt
```

`git restore --staged` does the same by another route, so whole-file `u` is refused too.
Whole-file `s` is allowed: `git add` on an unmerged path is how git itself is told that the
working tree holds the answer.

### Ignoring whitespace

A line folded away by ignoring whitespace is drawn as context, and a mixed view reads context
from the index. So the row shows the index version while the working tree holds another, and
writing the rows back leaves the file modified while the view shows nothing unstaged. With HEAD
and the index at `a b c` and the working tree at `a "  b  " C`:

| when staging every unstaged row | index afterwards                     |
| ------------------------------- | ------------------------------------ |
| counting whitespace             | `a` `  b  ` `C`, equal to the work tree |
| ignoring it                     | `a` `b` `C`, not equal               |

Comparing two alignments, one ignoring whitespace for display and one counting it for the index,
would lift this. They do not correspond row for row, so it is not a small change.

## Known gaps

- **The final newline.** Contents are written with one, so a file with no trailing newline gains
  one when part of it is staged. Fixing it means carrying whether each version ended with a
  newline along with its lines.
- **Modes other than a regular file.** An entry's mode comes from the index, or from the working
  tree's execute bit when there is no entry. A symlink or a submodule already in the index keeps
  its mode, but an untracked one would be staged as a regular file. Staging part of either is
  meaningless, so they belong with the cases that are listed and refused.
- **`assume-unchanged` and `skip-worktree`.** Whether `--cacheinfo` preserves these bits has not
  been measured. It matters for sparse checkouts.
- **`git add -N`.** `--cacheinfo` turns such an entry into an ordinary addition, which is probably
  what is wanted, but it is untested.
