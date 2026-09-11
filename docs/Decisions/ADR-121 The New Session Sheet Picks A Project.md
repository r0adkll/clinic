---
status: accepted
date: 2026-09-11
supersedes: what was left of ADR-032
tags: [adr, ui, sessions]
---
# ADR-121: The new session sheet picks a project

## Context
User (2026-09-11): *"When starting a new session from the empty/new screen It is using the old new
session dialog. I understand that this is needed so a user can select a project, but we could
greatly improve the UI/UX of this dialog to be more aligned with other new-Stuff UIs (like this new
session prompt, or the new automation dialog, etc)"*

`TabStore.startNewSession()` opens the composer ([[ADR-082 New Session Screen Composer]]) for the
project in view. With no project in view, it opens a sheet instead. That happens from the home
screen ([[ADR-120 The Empty Screen Is A Home]]), from ⇧⌘N *New Session in Folder…*, and from the
status item. Since ADR-120 made the home screen the landing page, that includes most first sessions
of the day.

The sheet was still [[ADR-032 New Session Flow]]'s grouped `Form`: a project `Picker` of raw paths,
a detached *Choose Folder…* button, model, effort, a worktree toggle, and *Start*. [[ADR-071 New
Session Screen]] said the sheet would be *"reduced to the folder picker"*, but it never was. As a
result:
- *Start* did not start anything. It opened the composer, which asked for model, effort and worktree
  again.
- The chosen model and worktree went to the per-project memory. Effort was read and then dropped.
- The project list had no icons and no sense of which project you last used, and you could not type
  to filter it.

## Options
- **Keep the form, restyle it.** Fixes the look, but it still asks twice.
- **Put a project picker in the composer.** One screen, but drafts are keyed by project, and
  ADR-120 already turned down a composer that picks the project for you.
- **A picker sheet that leads into the composer.** **Chosen.**

## Decision
- **The sheet only picks the destination.** Model, effort and worktree stay in the composer, which
  opens right after. The sheet's subtitle says so: *Choose where it runs. You write the prompt
  next.*
- **It uses the same visual language as the other "new" surfaces.** The header is an accent tile
  (the [[ADR-111 Nav Rows Wear Accent Tiles]] look at 34 pt) beside *New Session*. The filter field
  is styled like the composer card: text background, a hairline, and an accent ring while focused.
  The footer follows the automation editor: a secondary action on the left, *Cancel* and a
  prominent *Continue* on the right.
- **Rows look like the automation target list** ([[ADR-095 Automations]]): Chat first, a divider,
  then projects. Each row has the real project icon at 28 pt, the name, and the abbreviated path
  in monospace, truncated from the head. Chat shows its chord on the right. A project shows
  *N sessions · 2 hr. ago*, or *No sessions yet*.
- **Projects are ordered by their latest visible session**, not by sidebar order. Projects with no
  sessions come last, in sidebar order. The request's own project, when there is one (the status
  item passes it), is highlighted on open. Otherwise the most recent project is. It is never Chat,
  because New Chat has its own command.
- **The keyboard works like `QuickSwitcher`.** The field has focus on open, typing filters,
  ↑/↓ move the highlight, Return continues and Escape cancels. One click on a row also continues.
  Filter matches are ranked: the name starts with the query, then the name contains it, then only
  the path does. That way "ca" finds Campfire before a project that only has "Appli**ca**tion"
  somewhere in its path.
- **The keyboard highlight and the pointer look different.** The highlighted row gets an accent wash
  and a ↩ key cap. A hovered row gets a quiet fill. Otherwise, scrolling with the arrow keys under a
  resting pointer would leave two rows that look selected.
- **A folder dropped anywhere on the sheet** is registered as a project and goes straight to its
  composer, like *Choose Folder…*. The drop target shows an accent dashed overlay while a folder is
  over it. This is ADR-120's first-launch drop, applied to the sheet.
- **The list keeps a fixed height of 5½ rows.** The sheet doesn't jump while you filter, and a cut-off
  last row shows there is more to scroll.

## Consequences
- `NewSessionSheet.swift` is rewritten. It no longer writes `lastModelByProject` or
  `lastWorktreeByProject`; the composer's Send path still records them.
- `AccentTile` and `KeyCap` are no longer private to `HomeScreen.swift`.
- New smoke key (ADR-038): `-ClinicNewSessionSheetOnLaunch YES` opens the sheet once the first scan
  has landed.
