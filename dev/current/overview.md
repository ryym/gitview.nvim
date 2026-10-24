# Goal

Add a review mode to the status tab: a way to go through the files of a fixed
range one by one and mark each as reviewed, so that what has and has not been
read is kept track of while the range keeps changing.

- `gr` in the commits pane takes the same comparison `<CR>` would look into
  (one commit, a marked range, or the working tree) and starts a review of it.
  The files pane is replaced by the list of the range's files; the commits pane
  stays usable, look into included.
- Both ends of the range are fixed by sha when the review starts. A review
  started from the working tree row alone compares the HEAD of that moment with
  the working tree, so commits made during the review stay in it.
- `x` toggles a file as reviewed, from the list or from the diff, and `]x`/`[x`
  move to the next or previous file not reviewed yet. Checking from the diff
  moves on to the next one.
- When a reviewed file changes afterwards in the working tree, it is marked as
  changed since it was checked rather than unchecked silently. What is recorded
  is the content the diff was drawn from, so a write the diff has not picked up
  yet is not counted as read.
- `<BS>` in the list ends the review and brings back the uncommitted files.
  Checks live only in memory for the review's lifetime; discarding a review
  that is only partly checked asks first.
- Staging and switching the layer are refused during a review: the range
  compares two trees, with no index between them.

Out of scope: comments, persisting reviews, checking by hunk, and selecting
"from the working tree to this commit" in one key. The state is shaped so that
these can be added later.

# Context

Changes made by a coding agent tend to arrive in many commits and edits over
a session. Look into shows a range but keeps no state, so after a while it is
hard to tell which files were already read, and an edit made after reading a
file goes unnoticed. Code review tools solve this with a per-file "viewed"
mark that is reset when the file changes; this brings the same thing to the
status tab, against the working tree as well as commits.

Design decisions worth knowing:

- **The review list sits in the files pane, not the commits pane.** That keeps
  the commits pane free for looking into other commits while reviewing, which
  is why look into is kept rather than replaced.
- **A file of the review and the same file looked into are distinct**, even
  for the same range and path: what the diff pane shows, where it was left, and
  whether a drawn view can be reused all tell them apart. Only the review's diff
  shows the reviewed mark in its file header.
- **Change detection hashes line arrays in Lua**, since the diff's content is
  already at hand as lines. Every checked file is re-read on each refresh, with
  no shortcut such as mtime, because a missed change leaves unread content
  marked as read, the worst way for a review tool to be wrong. Whether that is
  too slow is to be measured as `docs/performance.md` describes.
- **No confirmation when every file is checked.** Ending a finished review is
  the common case; asking there trains the user to answer yes without reading.
