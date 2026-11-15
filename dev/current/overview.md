# Goal

Let `:Gitview` run any action, in one generic form, instead of a hand-picked few.

- `:Gitview run {action} [key=value ...]` calls `require('gitview.actions')[action]`
  with the arguments as a table.
  - A value `true` or `false` becomes a boolean; any other value stays a string.
  - A bare `key` is short for `key=true`.
- Every action that takes arguments takes them as one table, so that the command
  can pass them without knowing the action:
  - `close({ force = true })` (as before)
  - `set_shown_changes({ shown = 'staged' })`
  - `set_ignore_whitespace({ ignore = true })`
- An action raises an error on an argument it does not know, both when called
  from Lua and through `:Gitview run`. An action that takes no arguments raises
  an error if given some through `:Gitview run`.
- `:Gitview run` shows an action's error as a notification, not a stack trace.
  When the action does nothing (returns false), it says nothing, as a mapped key does.
- Every public function of `gitview.actions` is an action and is runnable.
- Subcommands that are not actions stay as they are: `:Gitview` (open) and
  `:Gitview review`. Those that wrapped an action are removed: `open`, `close`,
  `refresh`, `shown-changes`, `whitespace`.
- Completion covers the action names. Argument completion is out of scope.

Backward compatibility is not kept, for both the Lua API and the commands.

# Context

Only some actions had a subcommand. The rule behind the choice (acts on the whole
session and does not depend on the cursor) was consistent but not obvious to
users, who saw some actions as commands and others not. Commands are handy for
running an action without mapping a key, especially those with no default key
(`set_shown_changes`, `set_ignore_whitespace`, `show_last_focused_diff`), and
`:lua require('gitview.actions')...` is long to type.

A generic `run` makes every action a command without a rule to explain. It is
a subcommand rather than `:Gitview {action}` because non-action subcommands like
`review` may grow.

Command-line arguments are all strings while actions took a string, a boolean or
a table. Unifying arguments as a table lets `key=value` pairs map onto them with
no per-action schema.

Known limitation: from the command line, visual mode is already left, so an
action that works on a selection (`stage`, `unstage`, `toggle_check`) works on
the cursor line instead. This is accepted rather than passing a range.
