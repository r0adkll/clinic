---
status: accepted
date: 2026-09-07
tags: [adr, ui, projects, milestone-4]
---
# ADR-062: Project groups

## Context
Milestone 4 batch 1 ([[Collins Feature Gap]]). Collins: click a header to start a session, fold/unfold groups (remembered), collapse-all/expand-all, drag headers to reorder (persisted), an optional folder-path line, rows sorted by creation time so they don't jump, a sidebar "+" to add a project.

## Decision
- **Order**: projects listed in `ClinicState.projectOrder` come first in that order; the rest follow by last activity. Dragging a header onto another header inserts it there and writes the full order. "Reset order" in the project menu clears it.
- **Fold**: a chevron on each header; `ClinicState.collapsedProjects` persists; a sidebar toolbar row has collapse-all / expand-all and "+" (add project via the folder picker; ADR-050's Remove Project is the inverse).
- **Header click** starts a new session in that project (the existing sheet, pre-filled); the chevron and the ⋯ menu are the other targets.
- **Row options** (View menu, persisted in UserDefaults): "Show Folder Paths" adds the cwd as a second line; "Sort Sessions By" activity (default) or creation.

## Consequences
- The sidebar header stops being a plain `Section` label: it is a custom view with drag/drop of a project path.
