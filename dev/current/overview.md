# Goal

During a review, let the commits pane list the commits the review covers, and switch between
that list and the usual log with `gl`.

# Context

A review lists its files in the files pane, but the commits pane goes on showing the usual log.
For a review started from a ref (`:Gitview review main`), the log mixes in commits the review does
not cover: those of the base branch, and those merged in from it. Reading a review commit by commit
means picking out its commits by eye.

## The two lists

While a review is on, the commits pane holds two lists:

- **The review's list**, shown when the review starts: the commits of `<old>..<new>`, as
  `git log` gives them. `<new>` is HEAD for a review ending at the working tree, and the working-tree
  row heads the list as it heads the log. That HEAD follows the current one, so a commit made during
  the review appears in the list.
- **The usual log**, to look at commits outside the review without leaving it.

A review started from a range chosen in the commits pane gets the same kind of list, from the same
rule. Commits merged in from another branch are in it then, since the range's start does not reach
them, and the range's diff includes their changes too.

## Switching

- `gl` switches between the two lists. It follows the keys that change what the session does
  (`gr`, `gs`, `gw`), and needs no direction with two lists only.
- The winbar says which list is shown.
- Each list keeps its own cursor, mark, and the commit or range looked into or shown. Switching
  brings the other list's back, and the diff pane shows what that list has selected. The diff shown
  before switching can be reached with `show_last_focused_diff`.
- What is selected always belongs to the list shown, so `[r` and `]r` go through that list.
- The usual log keeps its state through the review, and is what the commits pane goes back to when
  the review ends.

## Within the review's list

- A range chosen in it is compared tree to tree, as anywhere else. When it holds a merge, the diff
  includes what the merge brought in from commits the list may not show, so the winbar says that the
  range holds a merge.
- `gr` is refused there, with a hint to choose the range in the usual log. Starting a review from it
  would look like a review nested in the current one, with `<BS>` going back to it, which it is not.
- A range whose older end is not an ancestor of its newer end (the log orders commits by date, so
  the two ends can sit on separate branches) lists what git gives for it, which leaves out the older
  end. Its diff already says `diverged`, so the list gets no special treatment.

## Out of scope

Showing a merge commit in the review's list as what the merge itself changed (re-merged with
`git merge-tree`) rather than against its first parent. That comes next; until then a merge in
the list is compared with its first parent, as in the log.
