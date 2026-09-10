---
status: accepted
date: 2026-09-07
tags: [adr, ui, sessions, milestone-2]
---
# ADR-045: Session overlays UI (rename, favorite, archive, search, quick switcher)

## Context
Milestone 2 batch 1 ([[Backlog]]). All of these are Clinic-side overlays keyed by session id ([[ADR-018 Claude Data Write Policy]], [[ADR-021 Persistence]]); the user asked for a way to get closed sessions out of the sidebar.

## Decision
- **Rename** via an `NSAlert` with a text field (⌘⇧R, context menu). Precedence unchanged ([[ADR-031 Session Naming Precedence]]); "Clear Custom Name" restores the CLI title.
- **Favorite** toggle (⌘⇧D); favorites appear in a "Favorites" section above projects and keep their project row.
- **Archive** (⌘⇧A) hides the row; archiving an open session closes its tab first with the usual confirmation ([[ADR-037 Close Quit and Exited Flows]]). "Undo Archive" (⌘⇧Z) pops an in-memory stack. "Show Archived Sessions" (View menu) reveals archived rows dimmed with an Unarchive action. No deletion of transcripts.
- **Search** is the sidebar's native search field: case-insensitive, every space-separated term must match name, first prompt, project name, branch or id.
- **Quick switcher** (⌘K): sheet with a text field, arrow keys, Return to open; same matcher; 30 results, most recent first.

## Consequences
- Auto-delete of archived sessions (Collins) is not adopted; archive is purely a view filter.
- The matcher lives in `SessionStore.matches` and is shared by both surfaces.
