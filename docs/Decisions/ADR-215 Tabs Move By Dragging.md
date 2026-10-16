---
status: accepted (built 2026-10-15; the drag itself awaits a check by hand)
date: 2026-10-15
supersedes: "[[ADR-212 A Session Is A Workspace Of Tabs]] (a tab's own move button), [[ADR-104 Panel Tabs Fit The Panel]] (\"not doing: drag to reorder\")"
tags: [adr, ui, tabs, panel]
---
# ADR-215: Tabs move by dragging

## Context
ADR-212 gave every tab a move button beside its ✕, pointing at the other area. User (2026-10-15): *"The tab
actions to move to the right or left is not good UX. It bloats the tabs and we should probably do the more
common desktop pattern of drag/drop"*.

## Decision
- **The move button goes.** A labelled chip is back to its glyph, its name and the ✕ (ADR-104).
- **A tab is dragged.** Dropped on another chip, it lands before that chip, in that chip's area. Dropped on a
  strip's empty space, it goes to the end of that area. Dropped on Claude's pinned chip, it lands first after
  Claude. One gesture covers both moving a tab to the other area and reordering it within its own, so ADR-104's
  "not doing: drag to reorder" is done too.
- **What shows:** the dragged chip as the preview, a short accent bar at the edge of the chip a drop would land
  beside, and a faint accent wash over a strip whose end would take it.
- **The payload** is the pane's id as text with a `clinic-pane:` prefix. Text dragged in from elsewhere, and a
  tab from another session's workspace, are refused. `TabStore.movePane(_:in:to:before:)` does the move and
  keeps the pane and its state.
- **The chip's menu keeps *Move to Right Panel* / *Move to Main Area***, as the way there without a pointer.

## Consequences
- Tabs cannot be dragged into another window or session, or out to Finder. Those stay with ADR-212's "not doing".
- A hidden right panel has no strip to drop on. Show it first (⌥⌘J), or use the menu.
- **Not verified by a script.** This session is not allowed to post synthetic events
  (`CGPreflightPostEventAccess() == false`), so clicks and drags sent with `CGEvent` were dropped silently, and
  not even a click on a chip registered. What was checked: the build, and the chips drawn without a move button.
  To check by hand in Clinic Dev:
  1. Open Files and Diff beside Claude, show the right panel, and drag Files onto the panel's strip. It moves
     there, and the strip shows a wash while it is over it.
  2. Drag it back onto the Diff chip. It lands before Diff, with an accent bar showing where.
  3. Drag Diff onto Claude's chip. It becomes the first tab after Claude.
