---
status: accepted
date: 2026-09-08
supersedes: parts of ADR-040, ADR-050, ADR-062, ADR-068
tags: [adr, ui, projects, sidebar]
---
# ADR-077: Persistent projects and sidebar polish

## Context
User feedback 2026-09-08, after living in the sidebar: projects vanish when their last session is
closed or archived, the order shuffles under you, the toolbar says "Sessions" above a list of
projects, the rows feel loose, and a selected row's hover actions are unreadable (accent-coloured
text on the accent-coloured selection fill).

The disappearing project was a real defect: membership was derived from *live* sessions plus
`ClinicState.addedProjects`, and only folders added through the "+" picker ever landed in that
array. A project first seen through ⌘N was therefore only as durable as its sessions — archiving
the last one, or closing a brand-new session before its transcript existed, dropped the whole
group. [[ADR-030 Project Grouping]] already required the opposite ("projects remain visible when
all sessions are archived").

## Decision
- **Membership is registered, not derived.** `ClinicState.projectsAddedAt: [String: Date]` records
  every project Clinic has seen, with the moment it first appeared. A project is registered when
  the user adds a folder, when Clinic starts a session in it, and when a session is imported. It
  stays until *Remove Project* (hides it and its sessions) or *Archive Project* (unregisters it;
  unarchiving a session re-registers it at its original position, per [[ADR-065 Repo Upkeep]]).
  `addedProjects` is gone; existing state files migrate from it plus `ownedSessions[*].addedAt`.
- **Default order is registration order, oldest first** — supersedes ADR-040's "most recent
  session activity" for *projects* (session ordering inside a project is unchanged) and ADR-062's
  "the rest follow by last activity". A project never moves on its own; new ones append at the
  bottom. Drag-to-reorder (`projectOrder`) and the pinned Chats group still come first.
  Ordering and membership live in `ProjectRoster` (ClinicCore) so they are unit-testable.
- **No "Sessions" caption.** The sidebar toolbar is the icon row alone (select, collapse-all,
  expand-all, add project), right-aligned and compact.
- **Row hover actions move to the trailing edge** — supersedes ADR-050's "replace the timestamp".
  They are icon buttons (Stop, Close, Star, Archive) that take the row's own label colour, so they
  stay legible on a selected row; the relative time no longer disappears out from under the
  pointer, and the row no longer reflows on hover.
- **Chats is permanent** — supersedes ADR-068's "hidden until it has a session; Remove Project
  hides it again". It is Clinic's own scratch group, not a folder the user added, so it is always
  pinned at the top with its "New Chat" placeholder: a starting point you can reach without first
  having used it. *Remove Project* drops off its menu (nothing to remove it to); *Archive Project*
  still clears its sessions.
- **An empty project still offers a way in**: a project with no sessions gets a placeholder row
  under its header — "New Session", or "New Chat" in the Chats group, matching the project menu's
  own wording — so a persistent-but-empty group is a starting point rather than a dead header.
- **Metrics.** Project header: 22 pt icon, `.body` semibold name, 12 pt chevron, 6 pt gaps, 3 pt
  vertical padding, 6 pt between the hover actions and the sidebar edge, and the count pill always
  shown. An 8 pt gap sits below the toolbar's divider, outside the scroll view so it cannot shift.
  Session rows are **not** indented under their project: an outline indent was tried at 28, 18,
  12 and 6 pt and rejected at every step — in a sidebar this narrow the icon-vs-glyph contrast
  already reads as nesting, and the indent only costs title width. Session row: 10 pt glyph, 8 pt gap,
  3 pt vertical padding, trailing badges 4 pt apart. Add-project is `folder.badge.plus`.
- **Metrics.** Project header: 22 pt icon, `.body` semibold name, 12 pt chevron, 6 pt gaps, 3 pt
  vertical padding, 6 pt between the hover actions and the sidebar edge, and the count pill always
  shown. An 8 pt gap sits below the toolbar's divider, outside the scroll view so it cannot shift.
  Session rows are **not** indented under their project: an outline indent was tried at 28, 18,
  12 and 6 pt and rejected at every step — in a sidebar this narrow the icon-vs-glyph contrast
  already reads as nesting, and the indent only costs title width. Session row: 10 pt glyph, 8 pt gap,
  3 pt vertical padding, trailing badges 4 pt apart. Add-project is `folder.badge.plus`.
- **The sidebar reads as an outline.** A project's children — session rows and the placeholder —
  indent by `childIndent` (6 pt, half the disclosure chevron) and then reuse the header's
  icon column (`glyphColumn` 22, `glyphGap` 6), so every leading glyph — state dot, `moon.zzz`,
  attention badge, the placeholder `+` — centres in one column instead of carrying its own width.
  Children are therefore only hinted as nested, not aligned under the project name: matching both
  the icon and the name columns needs 18 pt, and 18 → 12 → 6 all read as too deep in practice.
  Selection and hover fills stay full-width; only the content indents.

## Consequences
- One-time reshuffle on upgrade: folders added through "+" that never had a session sort to the
  top (their real add date is unrecoverable), everything else keeps the order of its first session.
- `ProjectRoster.paths(_:)` is pure, so "an archived project comes back where it was" is a test.
