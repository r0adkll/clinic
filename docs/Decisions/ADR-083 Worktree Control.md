---
status: accepted
date: 2026-09-08
supersedes: the worktree bullet of ADR-082
tags: [adr, ui, sessions, git]
---
# ADR-083: Worktree enablement and branch input

## Context
[[ADR-082 New Session Screen Composer]] folded the worktree option into the composer's chip bar: a pill
that toggled `draft.worktree`, and — when on — a bare borderless `TextField` wedged in beside it.

User (2026-09-08): "the worktree part of this could be better. I don't find its enablement and input
intuitive enough." Two distinct faults. **Enablement:** the pill was visually identical to the model and
effort chips, which are *menus*, so nothing said it was a boolean or which way it was set. **Input:** an
unlabelled field in a row of pills gave no hint that it was optional, what it named, or what it produced.

Considered and rejected: a single "Runs in" destination menu (current branch / new worktree…), which
merges enablement and input elegantly but duplicates the header's branch pill; and a full-width form row
under the card, which is the most conventional macOS shape but breaks the single-card look ADR-082 bought.

## Decision
- **The chip carries its own on/off mark** — a hollow circle when off, a filled checkmark when on — so it
  reads as a switch sitting between two menus rather than a third menu.
- **The branch name gets its own row inside the card**, revealed under the control bar when the toggle is
  on: a caption naming what happens (*"New branch from `<current branch>`"*), a bordered field with room to
  type, and, beside it, either the live destination `.claude/worktrees/<name>` or the explicit statement
  that Claude names the worktree when the field is left empty.
- **The header pill shows the relationship**, not just the current branch: `<branch> → <name>` in the accent
  colour while the toggle is on, falling back to "new worktree" before a name is typed. The consequence is
  visible where branch context already lives, so the footer goes back to its one job (⌘↩ / Empty Session).
- **Focus follows the toggle:** enabling worktree moves focus to the branch field, disabling it returns
  focus to the prompt. `@FocusState` is now a `Field?` rather than a `Bool`.

## Consequences
- `NewSessionScreen.worktreeControls` splits into `worktreeChip` and `worktreeRow`.
- Launch semantics are unchanged: an empty name still means no `-w` argument, and the CLI names the
  worktree and branch (ADR-071).
- New smoke keys (ADR-038): `-ClinicDraftWorktreeOnLaunch YES` and `-ClinicDraftBranchOnLaunch <name>`.
