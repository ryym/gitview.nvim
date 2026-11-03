# Usage

What gitview.nvim shows, what its keys do, and how to configure it. This is for
people using the plugin; how it is built is under [dev/](README.md#for-developers).

## The tab page

`:Gitview` opens a tab with a sidebar on the left and the diff on the right. The
sidebar is split in two: the uncommitted changes above, the recent commits below.
Moving the cursor in either draws whatever it lands on, and moving between the two
windows switches which list the diff follows.

- **The row the diff is showing has its name colored**, only in the window it
  follows, so which one that is can be read even while the focus is in the diff.
- **Coming back to a row shown before** puts the diff's cursor back on the line it
  was left on, or the one nearest it once the file has changed since.
- **There is one tab page per repository.** Running `:Gitview` again in the same
  repository goes back to the one already open.

The upper window has one row per file, with the two status letters
`git status --short` prints, laid out as a [tree of directories](#files-as-a-tree).
A file changed both in the index and in the working tree is still one row.

### Staying up to date

The tab keeps up with the repository on its own. Anything that writes the index —
`git add` in another terminal, a commit from a tmux pane, a branch switch from a
script — is noticed within a second and redrawn, and coming back to the tab page
re-reads it as well. So is a push or a fetch, which moves what counts as pushed.

`R` re-reads it on demand, for what those miss while you stay on the tab page: a
file written by something that never touched git, and the few commands that move
HEAD without writing the index, such as `git reset --soft`.

## Keys

`s`, `u`, `x` and `gy` also work on a visual selection. Each key can be changed;
see [Mapping keys](#mapping-keys).

| key         | action                        | in the files window | in the commits window | in the diff             |
| ----------- | ----------------------------- | ------------------- | --------------------- | ----------------------- |
| `<CR>`      | `focus_diff`                  | focus the diff      | on a commit's file    |                         |
| `<CR>`      | `look_into`                   |                     | look into the commit  |                         |
| `<BS>`      | `end_review`                  | end the review      |                       |                         |
| `<BS>`      | `back_out`                    |                     | back out of it        |                         |
| `m`         | `start_range`                 |                     | mark, for a range     |                         |
| `<Esc>`     | `clear_range`                 |                     | clear the mark        |                         |
| `gr`        | `start_review`                |                     | review the commit     |                         |
| `x`         | `toggle_check`                | check off rows      |                       | check off files         |
| `]x` / `[x` | `next_unread` / `prev_unread` | next file to read   |                       | next file to read       |
| `s` / `u`   | `stage` / `unstage`           | whole files         |                       | lines                   |
| `S` / `U`   | `stage_hunk` / `unstage_hunk` |                     |                       | a hunk                  |
| `gs`        | `cycle_layer`                 | staged / unstaged   | staged / unstaged     | staged / unstaged       |
| `gw`        | `toggle_ignore_whitespace`    | ignore whitespace   | ignore whitespace     | ignore whitespace       |
| `]f` / `[f` | `next_file` / `prev_file`     | next / prev file    | next / prev file      | next / prev file        |
| `]r` / `[r` | `next_commit` / `prev_commit` |                     |                       | next / prev commit      |
| `]c` / `[c` | `next_hunk` / `prev_hunk`     |                     |                       | next / prev hunk        |
| `gf`        | `open_file`                   | open the file       | open the file         | open it at this line    |
| `gy`        | `copy_location`               |                     |                       | copy the file and lines |
| `R`         | `refresh`                     | re-read             | re-read               | re-read                 |
| `q`         | `close`                       | close               | close                 | close                   |

`]f` and `[f` in a list move its cursor to the next file's row, passing over
directories, and in the commits window only among the files of a commit looked into.
In the diff they move to the next file's header, or, when it shows one file, the
list's cursor to the next file.

## The diff

Deleted and added lines share one column. There is no `+`/`-` column: a deleted
line has only its old number, painted red, and an added line only its new number,
painted green. Line numbers are decoration rather than text, so yanking a selection
gives you code and not a gutter.

Hunk boundaries match `git diff`. See [`linematch`](#options) for the one option
that trades this away.

### Several files in one buffer

A commit, a range of commits, or the working tree as a whole is shown with every
changed file's diff laid out end to end in one buffer, each file highlighted with
its own language.

- The working tree is read from disk, as git sees it. Unsaved edits in a buffer
  are not part of the diff until they are written.
- Added, deleted and renamed files are all handled.
- Binary files, changes with no textual difference such as a pure rename, and
  conflicted files with no conflict markers have no lines to show. They are
  listed by name at the top of the diff, below a commit's header, rather than
  dropped silently. Selected alone, they say as much in place of a diff.

### Folded unchanged lines

The lines away from any change are folded rather than left out, so a search still
finds them and a fold can be opened to see what a change sits in. A closed fold
reads as its first line that is not blank, followed by how many lines it holds.

`zo`, `zO`, `za` and `zA` open folds as usual, except a file's first fold, the
unchanged lines above its first change, which they open upwards so that the change
stays where it is on the screen. They hide a global mapping of those keys in the
diff. `zv`, `zR`, a fold opened by a search or the mouse, or another key mapped to
`za` opens a file's first fold as Neovim does. With `'wrap'` on, the change can move
by a row or two.

### Opening a file

`gf` opens the file in the tab page `:Gitview` was first run from, and leaves the
session open to come back to. From the diff it lands on the line under the cursor;
a deleted line lands on the line now in its place. A commit's line numbers are the
commit's, so there it lands near the line rather than on it.

### Copying where lines are

`gy` copies where the line under the cursor, or the selection, is in the file, such
as `lua/gitview/init.lua:12-18`, to point someone at it: a reviewer, or an agent
that wrote the change. It goes into the register given, so `"+gy` copies to the
clipboard.

- **Lines are numbered as the file now has them.** A deleted line among others
  counts as the line now in its place.
- **Deleted lines alone are numbered where they were**, and say so:
  `f.lua:3-5 (deleted from HEAD)`.
- **Lines the working tree lacks are numbered as the gutter has them** with one
  layer alone: a line only the index has is `f.lua:7 (in the index)` staged and
  `f.lua:7 (deleted from the index)` unstaged.
- **In a commit the commit is named**, as `f.lua:12 (at 1a2b3c4)`, since its line
  numbers are the commit's.
- **A selection over several files** copies a line for each.

## Staged and unstaged in one view

Uncommitted changes are shown as one diff from HEAD to the working tree, with each
changed line marked by whether it is staged.

Untracked files are included, every line of them an unstaged addition. Binary ones
are left out, as they are elsewhere.

### Reading it

The gutter reads `HEAD lnum | working-tree lnum | bar`. Line numbers are those of
HEAD and the working tree, so a line in neither has none. Two things mark a changed
line:

- **A `┃` bar** marks a line the index has changed, which unstaging would take back.
  It is green for a line the index added and red for one it deleted.
- **The diff colors** mark a line the working tree has changed since the index,
  which staging would record. A line with the bar and no further change has the same
  colors blended into the background instead.

Which versions have a line decides how it is shown:

| HEAD | index | work tree | shown as           | bar   | background |
| ---- | ----- | --------- | ------------------ | ----- | ---------- |
| yes  | yes   | yes       | unchanged          |       |            |
| yes  |       |           | deletion, staged   | red   | blended    |
|      | yes   | yes       | addition, staged   | green | blended    |
| yes  | yes   |           | deletion, unstaged |       | diff color |
|      |       | yes       | addition, unstaged |       | diff color |
|      | yes   |           | index only         | green | red        |

The last one is the one to watch for. The line would be committed, yet the working
tree no longer has it. It appears when a staged line is edited again or reverted
without re-staging, and is the only row with a bar and no number.

Two situations show changes even though HEAD and the working tree are equal, because
the index differs from both:

- A staged change reverted in the working tree: a staged deletion of the HEAD line,
  the index line with its green bar on red, then an unstaged addition of the
  working-tree line.
- A staged deletion restored in the working tree: a staged deletion then an unstaged
  addition of the same text. The index has no row for the line, so it cannot show as
  unchanged.

### Staging

Where the key is pressed decides what it acts on.

- **In the list**, `s` and `u` take the whole file, or every file of a directory in
  a tree, or of the rows a visual selection covers. A selection holding an unresolved
  conflict is refused.
- **In the diff**, they take the row under the cursor, or the rows a visual selection
  covers, and `S` and `U` take the whole change the cursor is in.

The two directions are never ambiguous even inside one hunk: `s` acts on the rows
that are not staged yet and `u` on the rows that are. Both lists are re-read from git
afterwards. Until they have been, another `s` or `u` is refused.

### Staged or unstaged alone

`gs`, from any of the three windows, shows the staged changes alone, then the
unstaged ones alone, then both again.

- **The files window lists the files with a change of that layer**, still with both
  status letters, and its winbar counts them as `5 staged` or `5 unstaged`. An
  untracked file is unstaged, and so is an unresolved conflict, which has nothing a
  commit would take.
- **The diff is the plain diff of the two versions that layer compares**, as
  `git diff --cached` and `git diff` print it, colored as an ordinary diff with no
  bar. Its winbar names them, `HEAD, staged` or `index, unstaged`, and the gutter
  numbers them: the index takes the right column staged and the left unstaged.
- **The diff's cursor stays on its line** when switching, and when the index changes
  under it.

Staging works as it does with both shown, with three differences.

- **`s` and `u` in the diff refuse to move rows into the layer shown**, where there
  is nothing to move, and say so.
- **A file left with nothing in the layer drops out of the list**, and the next file
  takes its place, shown from its header. A mistaken `u` is undone from the list
  after `gs` back to both.
- **After staging from the diff, the cursor goes on through the changes**: to what is
  left of the change, else to the file's next change, else it stays. Pressing `s`
  again goes on working down the file and never reaches into another file unseen.

A directory's row stages the files it lists, not those the layer hides. A range
ending at the working tree ignores the layer, having no index between its ends.

### Ignoring whitespace

`gw`, from any of the three windows, stops lines that differ only in whitespace from
counting as changed. The winbar says `-w`, as `git diff` would, while it is on, and a
file whose only change is whitespace says so rather than claiming to have no change
at all. `gw` again puts it back.

While it is on, `s` and `u` **in the diff** refuse: the rows on screen no longer
state the file faithfully, so staging them would leave it still modified. `s` and
`u` in the files window are unaffected, since they take the file as it is.

## Merge conflicts

A file with an unresolved conflict is shown as the working tree has it, conflict
markers included, rather than as a diff. It is read-only like any other diff.

- **Only the lines around each conflict are open**, and the rest is folded as
  unchanged lines are. `]c` and `[c` move between the conflicts.
- **Each part of a conflict has a background of its own**: ours green, theirs blue,
  and the base that `diff3` and `zdiff3` add red. They are fainter than an ordinary
  diff's, so a conflict is not taken for one. `<<<<<<<` and `>>>>>>>` are stronger in
  their side's color, and the markers between them gray.
- **The gutter has the working tree's line numbers only**, so `gf` opens the file on
  the line under the cursor, to edit it there.
- **The file's header counts conflicts** where it would count lines, as `!2`.
- **Syntax comes from the working tree, markers and all.** The markers themselves are
  left uncolored. Code inside or just after a conflict can be colored wrongly, since
  the file with its markers is not valid code.

A conflict is resolved by editing the file and pressing `s` on it in the list, which
is `git add`. Its lines cannot be staged from the diff, since the index has no single
version of the file to stage them into. A conflicted file with no markers left to
show, such as one that one side deleted, says so in place of the view.

## Files as a tree

The files window and the files of a commit looked into are laid out as a tree, under
a root row `./`:

```
▼ ./
 M README.md
▼ lua/gitview/
│  M init.lua
│ ▼ ui/
│ │  M list.lua
```

The status letters sit in front of each name. The rows are whole paths, with the
parent directory's part hidden and the letters only drawn, so yanking one gives the
full path. A directory holding nothing but another directory shares its row, as
`lua/gitview/` does. The root's files sit beside it rather than below.

The order is git's, not a file manager's: directories are not put first, and `a.lua`
comes before `a/`. It is the order `git diff` lists the files in, and the order `]f`
and a multi-file diff go by.

A directory row shows the diff of every file in it, and the root that of every file
listed, once the cursor has rested on it for a moment. Lines cannot be staged in it;
`s` and `u` on the row take every file in the directory instead. A directory holding
an unresolved conflict is refused either way, since staging the conflicted file would
mark it resolved unseen.

With `list_style = 'flat'`, the files are listed by their whole paths instead, with
no directory rows and the status letters at the left edge.

## Commits

The lower window lists the most recent commits, and putting the cursor on one draws what
that commit changed: the ordinary diff of
[several files in one buffer](#several-files-in-one-buffer). A merge is compared with
its first parent, the way `git show` does, and the winbar says `first parent`. A
subject too long for the winbar is cut short with `…`, so the file and the sha beside
it stay in view.

A commit row states its own sha and subject, so yanking one gives something that names
the commit elsewhere. Only the first four characters of the sha are shown; the rest is
concealed rather than dropped, so what is yanked is still the sha git abbreviates to.
`s` and `u` have nothing to stage there and say so.

Where the branch tracks an upstream, a commit's sha says whether it is pushed: what the
upstream already has is faded. A line such as `── origin/main ───` sits above the
commit the upstream points at.

### The commit header

Above the diff is what `git show --stat` would print before it: the subject, the author
and date, the body, and the stat. Below the subject, it starts folded into a single line
with who wrote it how long ago and the size of the commit. `zo` on the folded line opens
it, and a header opened stays open as the cursor moves on to other commits. A range of
two commits has no one message and shows no header.

### Looking into a commit

`<CR>` on a commit goes one level in: the list is replaced by the files that commit
changed, and selecting one shows that file's diff by itself. The uncommitted changes
above stay in view. `<BS>` comes back out, onto the commit you were looking at.

`]r` and `[r` in the diff move to the next and previous commit without leaving it, as
`j` and `k` would in the commits window. Next is the row below, the older commit, since
the list is newest first.

- **With a mark set**, only the cursor's end moves, so the range grows or shrinks.
- **Looking into a commit**, the adjacent commit is looked into instead, from its first
  file, so a series can be read a commit at a time. Looking into a range, there is no
  commit next to it, and the keys say so.

### Comparing two commits

`m` marks the commit under the cursor. While a mark is set, moving the cursor shows
every commit from the mark to the cursor in one diff, so a range is read by moving
rather than by marking twice. Those rows are colored as a selection is, and the winbar
counts them. `m` on another commit moves the mark there, and `<Esc>` clears it; with no
mark set, `<Esc>` does whatever it is mapped to elsewhere. `<CR>` works the same way, so
a range can be opened a file at a time.

Both ends are in the range, as in a selection: the diff starts at the first parent of
the older end, and the winbar names it `older^..newer`. Which end is the older one
follows from the list rather than from the dates: the row further down is the older
side.

A merge inside a range is nothing special. What does need saying is a range whose ends
are on branches that diverged: the older end is then not in the newer one's history, the
diff leaves it out and undoes whatever its branch did, and the winbar says `diverged`.

### Comparing with the working tree

The list is headed by a faded row of zeros standing for the working tree. On its own it
shows every uncommitted file in one view, staged and unstaged at once or the one layer
the files window shows, and `<CR>` there moves to the files window.

It is also an end a range can have, and the newest one. `m` on `HEAD~3` with the cursor
on the zeros reads that commit and everything since, committed or not, the way
`git diff HEAD~4` does; `<CR>` then lists those files. Untracked files are compared too,
as additions, which `git diff` itself would leave out. The row is there even when nothing
is uncommitted, so such a range can be set up first and then follows the edits as they
are made.

## Reviewing a range

`gr` in the commits window reviews what `<CR>` would look into: one commit, a range from
the mark, or the working tree. Its files take the place of the uncommitted ones in the
files window, and each can be checked off once read, so that what is left to read is plain
however many commits and edits the range takes in. The commits window stays as it is, and
other commits can be looked into meanwhile. `gr` while looking into a range reviews that
range instead.

- **The range is fixed when the review starts.** The working tree on its own is reviewed
  from the commit HEAD is on at that moment, which the winbar names by its sha: what is
  committed during the review stays in it.
- **`x` checks off a file**, or every file of a directory or a selection, and takes the
  checks off again once all of them are checked. In the diff it checks off the file being
  read, or every file a selection touches, and goes on to the next one still to be read.
  `]x` and `[x` go to the next and previous one, round from the other end, in the diff
  and in the files window alike.
- **A file checked off is marked `✓` and faded**, in the list and on its header in the
  diff. A directory is marked and faded once every file in it is. The files window's winbar
  counts them, as `3/12`.
- **A file that changes after it was checked off is marked `!`**, rather than unchecked,
  and counted apart, as `3/12 !1`. It is read again, and checked again with `x`, and a
  directory with such a file in it is marked `!` too. Only a range ending at the working
  tree can change. What a check records is what the diff showed, so a file rewritten while
  it was being read is not taken as read.
- **`<BS>` in the files window ends the review**, and the checks go with it. A review only
  part way through asks first, and so do `gr` starting another and `q`; a finished one
  does not.

Nothing is staged during a review, and `gs` does not switch the layer: a range compares
two trees, with no index between them.

## Configuration

`setup()` is optional, and only carries these options. The values below are the defaults.

```lua
require('gitview').setup({
  context = 3,
  algorithm = 'histogram',
  linematch = 0,
  ignore_whitespace = false,
  layer = 'both',
  list_style = 'tree',
  list_ratio = 0.25,
  commit_count = 100,
  commit_ratio = 0.4,
  no_highlight = {},
  default_keymaps = true,
})
```

### Options

| option              | what it sets                                              |
| ------------------- | --------------------------------------------------------- |
| `context`           | unchanged lines left open around each hunk                |
| `algorithm`         | the `vim.diff()` algorithm                                |
| `linematch`         | see below                                                 |
| `ignore_whitespace` | where every diff starts out                               |
| `layer`             | `both`, `staged` or `unstaged`                            |
| `list_style`        | `flat` or `tree`                                          |
| `list_ratio`        | share of the width the sidebar takes, 30 columns at least |
| `commit_count`      | how many recent commits it lists                          |
| `commit_ratio`      | share of the sidebar height the commit list takes         |
| `no_highlight`      | filetypes left unhighlighted; see below                   |
| `default_keymaps`   | see [Mapping keys](#mapping-keys)                         |

- **`linematch`**: Neovim's pass that re-pairs lines inside a hunk and splits it,
  disagreeing with git. It is off so that hunk boundaries match `git diff`, and can be
  turned on with a value such as `60` at the cost of that agreement. Both sides are
  measured in [neovim-notes](dev/neovim-notes.md#linematch-disagrees-with-git).
- **`no_highlight`**: a language without a Tree-sitter parser is highlighted through its
  Vim syntax file, loaded again for both versions of every such file in a view. Some are
  slow to load, especially with many highlight groups defined, and a commit touching many
  of them can take noticeably longer to open. Listing a filetype, as `{ 'scss' }`, shows
  its diffs with the diff colors only. Installing the language's Tree-sitter parser avoids
  the cost without giving up the colors.

### Commands

`:Gitview` with no argument opens a tab page. The rest act on the tab page of the current
one, and say so when it has none.

| command                  | what it does                          |
| ------------------------ | ------------------------------------- |
| `:Gitview open`          | the same as `:Gitview`                |
| `:Gitview close`         | close, asking about a review part way |
| `:Gitview refresh`       | re-read the repository                |
| `:Gitview layer`         | show the next layer, as `gs` does     |
| `:Gitview layer {layer}` | `both`, `staged` or `unstaged`        |
| `:Gitview whitespace`    | toggle ignoring whitespace, as `gw`   |
| `:Gitview whitespace on` | ignore whitespace; `off` to stop      |

### Actions

Everything a key does in the tab page is a Lua function of `require('gitview.actions')`,
named in the [table of keys](#keys). Each acts on the tab page of the current one, in the
window the cursor is in. Two more have no key: `set_layer(layer)` and
`set_ignore_whitespace(bool)`.

The actions, the subcommands and the filetypes may still change in name or arguments until
the plugin is stable.

- **`close()` asks first** if a review is part way through, as `q` does.
  `close({ force = true })` does not.
- **`gs`, `gw`, `R`, `q` and the two setters work in any window of the tab page**, such as
  help opened there, as well as its three windows. The other actions do nothing outside the
  windows they work in.
- **`look_into` on the working tree** focuses the files window, as `<CR>` does.
- **`start_review`, `toggle_check`, `stage` and `unstage` say why they do nothing** in a
  window where they mean nothing, as the default keys do in the commits window.

Every action returns whether it did anything. `true` covers a message saying why it could
not; `false` means nothing happened and nothing was said, so the key is free for something
else. That is the case with no tab page, outside the windows the action works in, and where
there is nothing to do: `clear_range` with no range, `back_out` with nothing looked into,
`end_review` with no review, `look_into` while looking into a commit already, a move with
nowhere to go, or a setter given the value already set.

What an action sets off may not be over when it returns. The action itself is: the cursor
has moved, or the index has been written, or the file checked off. Re-reading the status
and drawing the diff can come later. After `stage()`, for one, the index has changed but
the windows have not, and another `stage()` is refused until they have. `refresh()` is all
of it later.

### Filetypes

| window             | filetype          |
| ------------------ | ----------------- |
| the files window   | `gitview-files`   |
| the commits window | `gitview-commits` |
| the diff           | `gitview-diff`    |

`FileType` runs in that window, once its default keys are mapped. A key mapped from
there replaces the default one, and a window option set there applies to that window.

### Mapping keys

Keys are changed the way they are in any other buffer: mapped from a `FileType` autocommand
or an ftplugin. There is no table of keys in `setup()`.

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'gitview-files', 'gitview-commits', 'gitview-diff' },
  callback = function(ev)
    local a = require('gitview.actions')
    local opts = { buffer = ev.buf, nowait = true }
    -- move s to <C-s>
    vim.keymap.del({ 'n', 'x' }, 's', { buffer = ev.buf })
    vim.keymap.set({ 'n', 'x' }, '<C-s>', a.stage, opts)

    -- go on to the next file after the last change
    if ev.match == 'gitview-diff' then
      vim.keymap.set('n', ']c', function()
        if not a.next_hunk() then
          a.next_file()
        end
      end, opts)
    end
  end,
})
```

- **Give the mapping `nowait`.** Without it, a key that begins a global mapping waits for
  the rest of it, and runs that mapping when the next key comes soon enough: `m` and then
  `d` would be someone's `md`.
- **Map to the function, or to `<Cmd>`**, for an action taking a visual selection. A mapping
  going through the command line, as `:<C-u>lua ...<CR>` does, has left visual mode before
  the action runs.
- **Look at the return value to pass a key on.** The default `<BS>` and `<Esc>` do what they
  are mapped to elsewhere when the action does nothing:

  ```lua
  vim.keymap.set('n', '<Esc>', function()
    if not a.clear_range() then
      vim.cmd.nohlsearch()
    end
  end, opts)
  ```

- **`vim.keymap.del` fails on a key the window does not map.** The windows map different keys;
  see the [table of keys](#keys).
- **`<CR>` and `<BS>` are different actions by window.** A key mapped in more than one window
  picks its action by `ev.match`. The default `<CR>` of the commits window is
  `a.look_into() or a.focus_diff()`.

`default_keymaps = false` turns every default key off, so that you can map them all
yourself. That takes the diff's `zo`, `zO`, `za` and `zA` with them; see
[Folded unchanged lines](#folded-unchanged-lines).

### The diff's own line numbers

The numbers in a diff's gutter are the files' lines, while `G` and `:N` go by the rows of the
diff buffer. Its own numbers are shown before the gutter, at the cost of a third column of
numbers, when `'number'` or `'relativenumber'` is on in the diff's window. Both are off there
to begin with, whatever they are elsewhere. To turn them on, set them in an ftplugin of the
`gitview-diff` filetype, such as `after/ftplugin/gitview-diff.lua`:

```lua
vim.opt_local.number = true
vim.opt_local.relativenumber = true
```

A `FileType` autocommand does the same, if it is created before the tab page is opened.

### Window options

The three windows are given some window options before their filetype is set, which an ftplugin can
change:

| window  | options                                |
| ------- | -------------------------------------- |
| files   | `'wrap'`, `'cursorline'`               |
| commits | `'wrap'`                               |
| diff    | `'wrap'`, `'cursorline'`, line numbers |

The rest of the options they are drawn with are set after it, over whatever an ftplugin set:

- **Both lists**: `'statuscolumn'`, `'winbar'`, `'number'`, `'relativenumber'`,
  `'signcolumn'`, `'conceallevel'`, `'concealcursor'`, `'winfixwidth'` and `'winfixbuf'`.
- **The commits window**, as well: `'cursorline'`, which is off while a range is shown, and
  `'winfixheight'`.
- **The diff**: `'statuscolumn'`, `'winbar'`, `'signcolumn'`, `'foldcolumn'`, `'foldmethod'`,
  `'foldexpr'`, `'foldtext'`, `'foldenable'`, `'foldlevel'`, `'foldminlines'` and `'winfixbuf'`.

The gutter is drawn by `'statuscolumn'`, so `'signcolumn'`, `'foldcolumn'` and, in the lists,
the line numbers would only take room beside it. Options these windows are not given, such as
`'scrolloff'` or `'colorcolumn'`, are yours as they would be in any other window. `:setlocal`
once a window is open is not stopped, though changing an option it is drawn with can leave it
drawn wrong.

### Highlight groups

Every group is defined the first time it is needed, and redefined on `ColorScheme`. Defining
any of them yourself takes precedence, whether or not `setup()` is called.

| where             | groups                                                                                                                                                      |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| the diff          | `GitviewAdd`, `GitviewDelete`, `GitviewAddText`, `GitviewDeleteText`                                                                                        |
| the gutter        | `GitviewOldLnum`, `GitviewNewLnum`, `GitviewAddLnum`, `GitviewDeleteLnum`, `GitviewFoldBar`                                                                 |
| staged lines      | `GitviewStagedAdd`, `GitviewStagedDelete`, `GitviewStagedAddText`, `GitviewStagedDeleteText`, `GitviewStagedAddBar`, `GitviewStagedDeleteBar`               |
| conflicted lines  | `GitviewConflictOurs`, `GitviewConflictTheirs`, `GitviewConflictBase`                                                                                       |
| conflict markers  | `GitviewConflictOursMarker`, `GitviewConflictBaseMarker`, `GitviewConflictSeparator`, `GitviewConflictTheirsMarker`                                         |
| a file's header   | `GitviewFileHeader`, `GitviewFileHeaderBg`, `GitviewFileHeaderStatAdd`, `GitviewFileHeaderStatDelete`, `GitviewFileHeaderConflictCount`, `GitviewSeparator` |
| a commit's header | `GitviewCommitSubject`, `GitviewCommitAuthor`, `GitviewStatAdd`, `GitviewStatDelete`                                                                        |
| files left out    | `GitviewSkipped`                                                                                                                                            |
| the sidebar       | `GitviewStatusStaged`, `GitviewStatusUnstaged`, `GitviewStatusUntracked`, `GitviewListCursor`, `GitviewRange`                                               |
| commits           | `GitviewCommitSha`, `GitviewCommitShaPushed`, `GitviewCommitWorktree`, `GitviewUpstream`, `GitviewUpstreamRule`                                             |
| a tree            | `GitviewDirectory`, `GitviewIndent`                                                                                                                         |
| a review          | `GitviewReviewedMark`, `GitviewReviewed`, `GitviewReviewChanged`                                                                                            |
| the diff's winbar | `GitviewCommitSha`, `GitviewWinBarText`                                                                                                                     |

The defaults follow the colorscheme:

- **The diff colors** are backgrounds derived from `DiffAdd` and `DiffDelete`.
- **The conflict colors** are faded backgrounds derived from `DiffAdd`, `DiffChange` and
  `DiffDelete`, with gray between the sides.
- **`GitviewFileHeaderBg`** is derived from `CursorLine`, and **`GitviewFileHeader`** is bold
  text in the surrounding color.
- **`GitviewWinBarText`** is the winbar's colors without its bold.
- **`GitviewStatAdd`, `GitviewStatDelete`, `GitviewStatusStaged` and `GitviewStatusUnstaged`**
  take the text color of `Added`, `Removed` or `Changed`. Where the colorscheme gives those a
  background, they take that of the `diff*` and `GitSigns*` groups for the same change.
- **The rest** link to standard groups.

## Known limitations

- **No LSP semantic tokens.** Highlighting is purely syntactic.
- **Languages without a Tree-sitter parser need `:syntax` enabled.** They fall back to it, and
  a Tree-sitter-only setup gets no colors there. Highlighting them is also slower.
- **A line longer than `'synmaxcol'` gets neither syntax colors nor word highlights**, only its
  background. Unlike Vim, the whole line goes uncolored, not only the part past the limit.
  Collecting colors for minified code costs seconds per line; to lift the limit anyway, set
  `'synmaxcol'` to `0` in the diff buffer, whose filetype is `gitview-diff`.
- **The winbar can be taken over by your config.** The file at the top of the window is reported
  through `'winbar'`, so a configuration or plugin that sets it for every window hides it. Every
  file still has its own header line in the buffer.
- **A merge conflict can only be read, not merged.** There are no keys to take one side or the
  other; the file is edited after `gf`, and marked resolved with `s` on it in the list. It is
  listed as `UU` whichever pair git would print, and its syntax colors can be off around a
  conflict.
- **A range ending at the working tree shows conflict markers as added lines.**
  `git diff <commit>` reports an unmerged file as an ordinary change, and the markers are in the
  working tree.
- **A file with no trailing newline gains one** if part of it is staged.
- **Discarding changes and committing are not implemented.**
- **Everything is computed eagerly** when the diff opens, and grows linearly with the number of
  files.
