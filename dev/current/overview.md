# Goal

In a review's list of commits, show a merge commit as what was done in the merge itself: how its
conflicts were resolved, and anything else changed on top of merging the two sides.

# Context

A merge commit is compared with its first parent, as `git show` does. During a review that buries the
merge's own changes under everything the other parent brought in: for a feature branch that merged
`main`, all of `main`'s changes since the last merge. In the review's list those are not the
feature's changes, and its other commits already show the feature's own, so what is left to review in
a merge is what was done by hand.

## The comparison

A merge commit `M` with parents `p1` and `p2` is `git merge-tree --write-tree p1 p2` (call it `R`),
which redoes the automatic part of the merge in memory, plus what was done by hand. So `M` is compared
with `R`:

- What merged cleanly is the same in `R` and `M`, and leaves the diff.
- A file that conflicted holds its conflict markers in `R`, so its diff goes from the markers to the
  resolution.
- `R` is a tree in the object database, so the comparison is an ordinary one between two trees.
  `merge-tree` touches neither the working tree nor the index; the objects it writes are unreferenced
  and left to `git gc`.

This is what `git show --remerge-diff` shows. Within the review's list it applies to a merge on its own,
to looking into it, and to stepping through it with `[r`/`]r`. A range of several commits is still
compared tree to tree. The log is unchanged: there, nothing says which side a merge is to be read
against, so it keeps the first parent.

The winbar says nothing of it: the diff reads as a merge's own changes would, and the comparison is
documented in the README.

## Conflicts with nothing to show

A conflict that cannot be marked out in a file (modify/delete, rename/delete, file/directory, ...) is
settled by git leaving one side's version in `R`. When the merge kept that version, `M` and `R` agree,
and the diff would not show that a side was dropped. Such a file is listed among the files the view
leaves out, as binary files are, with the kind of conflict:

```
d   (modify/delete conflict, resolved as git left it)
```

A content conflict needs no such line: its diff from the markers already shows it was one.

## Where it falls back

The merge is compared with its first parent, and the winbar says why, when:

- git is older than 2.39, whose `merge-tree --write-tree` does not yet say in a form to be read which
  kind of conflict each file had
- the merge has more than two parents, which `merge-tree` cannot redo

Falling back silently would show the other side's changes as if they were the merge's own.

## Known limits

`R` is the merge as git would do it now, with the current configuration. Whatever differs from how the
merge was actually made shows up as changed by hand: a strategy option such as `-X ours`, a custom merge
driver, rerere, another version of git. The marker style follows `merge.conflictStyle`. Each of these
shows more than was done by hand, never less.
