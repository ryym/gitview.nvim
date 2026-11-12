# Goal

Let a review start from a base ref given on the command line, so that what a branch
changed since it left another one can be reviewed as a whole:

- `:Gitview review <base>`: from `merge-base(<base>, HEAD)` to the working tree,
  untracked files included
- `:Gitview review <base> <new>`: from `merge-base(<base>, <new>)` to `<new>`

The review that follows works as one started with `gr` does: the files pane lists the
range's files, and they are checked off one by one.

# Context

A review today starts from a range chosen in the commits pane, which compares two trees.
Once the base branch has been merged into a feature branch, no such range shows "what the
feature branch changed": any range across the merge also brings in the base's changes it
merged. What is wanted is `main...feature`, the changes since the merge-base, which is how a
pull request on GitHub is compared too. A ref also reaches commits the commits pane has not
loaded, such as an old tag.

The behaviour:

- `<base>` is required. A missing one is an error that shows the usage. Guessing a base
  (`origin/HEAD`, the upstream, ...) would differ by repository and could review the wrong
  range unnoticed. A default can be added later without breaking anything.
- Both ends are resolved to shas when the review starts, as every review's ends are. A ref
  that moves meanwhile does not change the range.
- No merge-base (unrelated histories) is an error. With several (a criss-cross merge), the
  first one git gives is used.
- The label is `<base>...working tree` or `<base>...<new>`, as the refs were typed.
- Run outside a Gitview tab page, the command first does what `:Gitview` does: it goes to the
  repository's Gitview tab page, or opens one. It asks before replacing a review part way
  through, as `gr` does. A range being looked into in the commits pane is left as it is.
- `<base>` and `<new>` complete to ref names: branches (remote ones too), tags and `HEAD`.

Out of scope for this work, planned as a later step:

- A list of the range's commits in the commits pane during a review, switched with the usual log
- Showing a merge commit in that list as what the merge itself changed, re-merged with
  `git merge-tree`, rather than against its first parent
