---
status: accepted (built 2026-10-15)
date: 2026-10-15
supersedes: "[[ADR-212 A Session Is A Workspace Of Tabs]] (the openers at the trailing end of the main area's tab row)"
tags: [adr, ui, tabs, panel]
---
# ADR-213: The `+` menu replaces the openers

## Context
[[ADR-212 A Session Is A Workspace Of Tabs]] moved the footer's quick actions to the trailing end of the main
area's tab row: Terminal, Files and Diff always, then Media, Grill and each PR. After trying step 1, the user
(2026-10-15): *"If it helps, we can drop the tab helpers at the end of the main panel (i.e the terminal, diff,
files) shortcuts. We should just access all those from the '+' button"*.

The openers repeated what the `+` menu and the chords (⌘J, ⌘⇧E, ⌘⇧G…) already do. They also took width from
the row the session's own tabs live in, and from a toolbar whose header already had to be capped so the
controls after it fit.

## Decision
- **The openers go.** The main row's trailing end keeps only the zoom and the panel toggle.
- **The main area's `+` is where every view is reached.** *Add* opens a view beside Claude (Media, Grill,
  pull requests and runs included, as before). *Open* lists Claude and the main area's tabs. A new section,
  *In the Right Panel*, lists the panel's tabs, so a view that is already open over there is one pick away
  instead of offered again or missing.
- **The chords and agent tools are unchanged**: they front a view where it is open, else open it in the right
  panel (ADR-212).

## Consequences
- The main row no longer shows at a glance which views are open behind another tab (ADR-079's filled, outlined
  and plain). The tabs themselves, and the `+` menu, show it.
- A session's PRs are no longer one click from the main row. They are under the `+` menu's *Add*, the empty
  right panel's *This session* list (ADR-172) and ⌘⇧P for the newest.
