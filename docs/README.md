# Documentation

## For developers

| document                                   | what it covers                                 |
| ------------------------------------------ | ---------------------------------------------- |
| [dev/architecture.md](dev/architecture.md) | The parts of the plugin and the rules they share |
| [dev/staging.md](dev/staging.md)           | How the index is written, and where that has holes |
| [dev/performance.md](dev/performance.md)   | Where the time goes, and how to measure it     |
| [dev/neovim-notes.md](dev/neovim-notes.md) | Measured Neovim and git behaviours to rely on  |
| [dev/testing.md](dev/testing.md)           | How the suite runs and how to add to it        |

## Documentation policy

The documents describe the current design and behaviour. They are not a log: when
a documented choice is overturned, rewrite that passage rather than appending a
correction. Each document says who it is for and what it covers at the top, and
keeps to that. State each fact in one place, and link to it from elsewhere.

### User documents

The README is a short overview. The specification of what a user sees and can
configure belongs in the user documents, independent of how it is implemented.
Users do not read the code, so what they would want to know is written out.

### Developer documents

Developer documents are a map for reading the code, not a description of it.

Include only:

- **The overall shape**: which parts exist, what each is responsible for, and how
  they relate.
- **Rules no single file shows**, such as an invariant kept across several modules.
- **The reason for a choice** a reader would otherwise likely "fix" or undo, when
  the choice spans several files. If it lives in one place in the code, its reason
  belongs in a comment there, where anyone about to change it will read it.
- **What is costly to learn from the code**, such as measured behaviour of Neovim
  or git, and known gaps.

Leave out:

- **Internal details**: function names, data shapes, algorithms and step-by-step
  flows.
- **Consequences** that follow from a stated rule, and conventions any developer in
  the field would assume.
- **Justifications against a previous design**. The motivation for a change belongs
  in the commit message.

When in doubt, leave it out. A detail missing from the documents can be found in
the code, while an overly detailed document is a maintenance burden and goes stale.
