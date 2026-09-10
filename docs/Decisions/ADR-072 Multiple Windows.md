---
status: accepted
date: 2026-09-08
tags: [adr, ui, architecture, milestone-3]
---
# ADR-072: Multiple Windows

## Context
[[ADR-019 Window and Surface Lifetime]] chose one window for milestone 1 and deferred more. Collins lets sessions live in several windows that share one state, and a session runs in exactly one tab ([[ADR-041 One Tab Per Session]]). Last of the milestone 3 polish group.

## Decision
- **One `TabStore`, many windows.** The store still owns every tab and surface; each `Tab` carries a `windowId`, and a `WindowState` (selection, new-session draft, sidebar select mode) exists per window. Commands act on the **active window** (the last key window). `WindowGroup(id: "main", for: UUID.self)`; the window launched by the system is the primary window (a fixed id), others are opened by value.
- **Where tabs go.** New tabs open in the active window. Selecting a session that is open in another window focuses that window's tab (ADR-041). A tab moves with *Move to New Window* / *Move to Window ▸* (tab bar context menu, session context menu, Tabs menu); a project's *New Session in New Window* opens the new-session screen in a fresh window.
- **Content hosting.** The content area is one AppKit `TerminalStackView` per window that adds and hides each tab's persistent `TabContentView`; it only removes views that are still its own subviews, so moving a tab between windows is a plain re-parent no matter in which order SwiftUI updates the two windows. SwiftUI never owns a surface (ADR-019, refined 2026-09-07).
- **Closing.** Closing a window that is not the last one moves its tabs to another window — nothing is stopped. Closing the last window keeps the [[ADR-069 Keep Running and Quit Behaviour]] flow. AppKit state restoration is opted out (`ApplePersistenceIgnoreState` at launch, windows `isRestorable = false`) — open tabs are not restored anyway ([[ADR-042 Launch Restoration]]) and saved state from a build with another scene shape produced *no* launch window at all; the primary window keeps its frame through an AppKit autosave name and secondary windows cascade from the key window.
- Attention ([[ADR-066 Attention]]) treats "looking at it" as: app active, tab's window is the active window, tab selected there.

## Consequences
- `tabs.selectedTab`, `selectedTabId` and `editingDraft` forward to the active window so existing call sites keep working.
- Sheets driven by app-wide notifications (⌘K, details, MCP servers, new-session folder picker) are presented by the active window only.
