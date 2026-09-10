---
status: accepted
date: 2026-09-08
tags: [adr, ui, sessions, milestone-3]
---
# ADR-074: Sidebar Multi-Select (select mode)

## Context
Collins has a select mode for bulk open/star/archive/trash. Clinic's sidebar is a native `List`, and single-click opens a session ([[ADR-045 Session Overlays UI]]).

## Decision
- **Native multi-selection always works**: ⌘-click and ⇧-click extend the sidebar selection without opening anything; a plain click still opens (or focuses) one session. The context menu is the list's selection menu: one row → the usual session menu, several → the bulk menu.
- **Select mode** (sidebar toolbar button, View → *Select Sessions*, default ⌘⇧S) shows a checkbox per row and an action bar with the count; ⎋ or *Done* leaves it. It exists for discoverability and for building a selection with plain clicks.
- Bulk actions: Open, Close Tabs, Add/Remove Favorites, Archive, Mute/Unmute. Archive runs the per-session flow (closes tabs with confirmation, offers worktree trash, [[ADR-065 Repo Upkeep]]). No trash/delete ([[ADR-018 Claude Data Write Policy]]).

## Consequences
- Selection state (bulk set, select mode) is per window ([[ADR-072 Multiple Windows]]).
