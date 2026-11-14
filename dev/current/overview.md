# Goal

Squash `fixup!` and `amend!` commits from the commits window: `A` on a commit runs
`git rebase -i --autosquash` from that commit's parent, as typing it by hand would, without leaving
the session.

# Context

Folding fixups in is a routine step before pushing, and the commits window already shows which
commits they are. Running it means leaving the session for a terminal and working out which commit
to rebase from. The commit under the cursor is that answer: every `fixup!` / `amend!` from it up to
HEAD is folded in, whichever commit each one targets, so any commit older than their targets works.

## What it does

```sh
GIT_SEQUENCE_EDITOR=: GIT_EDITOR=: git rebase -i --autosquash --no-autostash <sha>^
# --root in place of <sha>^ for a root commit
```

- No confirmation is asked. The message names HEAD from before, e.g.
  `autosquashed (HEAD was 5d6e7f8)`, which is enough to undo it; `nothing to squash` when HEAD did
  not move.
- Neovim is not blocked while it runs.
- A failure, a conflict included, is reported with git's own message, and the rebase is left where
  it stopped. Resolving it, `--continue` and `--abort` are left to the user outside Gitview.
- `-i` is required: `--autosquash` without it needs git 2.44, and Gitview supports 2.31.
  `amend!` is understood from git 2.32; on 2.31 it stays an ordinary pick.

## When autosquash is not run

`A` refuses to run the rebase, saying why, in two kinds of case.

When the cursor is on nothing to rebase from:

- the `0000` row
- a commit's files being looked into
- a range being chosen
- another autosquash still running

When the rebase would do harm git does not check for. These are checked on the commits to be
rewritten: the commit itself and every commit after it up to HEAD. They are read from the
repository when `A` is pressed, not from the list on screen, which may be out of date:

- the commit is not an ancestor of HEAD; git would transplant the branch onto it
- a merge commit is in the range; git would linearize it
- a `squash!` commit is in the range; its message is meant to be edited by hand, and with no
  editor to do it the two messages would be committed concatenated as they are
- during a review, an end of the review fixed by sha is in the range; the review would go on
  showing commits that no longer exist

What git refuses itself, such as a dirty working tree, is left to git, and its message is shown.

## While it runs and after

- Gitview does not re-read the repository until it ends, whatever asks: drawing a half-done rebase
  would only disturb the cursor and the held-back list. `R` says a rebase is running; writing the
  index is refused. A working-tree diff picked meanwhile may show the rebase half done, and is
  redrawn when it ends.
- When it ends, either way, the repository is re-read and the cursor moves to the rewritten
  commit it was started from. Without that, a commit dropped from the log would hold the old list
  open, and the stopped state would not be shown.
  - That commit is always found: the range is linear, so it is the only child of the commit
    rebased onto, and as the oldest in the range it is never folded into another.
  - It moves only while the diff still shows the commit `A` was pressed on, so as not to pull the
    user back from whatever they went on to look at.

## Out of scope

- Resolving conflicts, or showing or continuing a rebase in progress. If done, it belongs to
  sequencer operations in general (merge and cherry-pick too), not to autosquash.
- `squash!`, which needs its message edited, and editing the todo list.
- Warning about rewriting pushed commits.
