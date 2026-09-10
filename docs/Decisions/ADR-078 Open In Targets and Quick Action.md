---
status: accepted
date: 2026-09-08
tags: [adr, ui, sessions]
---
# ADR-078: Open In targets and the footer quick action

## Context
The "Open In" submenu ([[ADR-063 Session Lifecycle Controls]], [[ADR-050 Project Decoration and Actions]]) listed Finder, Ghostty and the installed editors as plain text, so picking the right one meant reading a list of names. There was also no way to open the session that is already on screen without going back to its sidebar row.

## Decision
- **One registry.** `OpenInApps` (app target, main actor) resolves the destinations once — Finder, Ghostty when its binary is found, and the editors of ADR-063 that Launch Services knows about — and caches each target's app icon per size. It re-resolves when older than 60s, so an editor installed while Clinic runs shows up.
- **Menu rows carry the app icon.** Every "Open In" row is `Label { name } icon: { app icon }`. SwiftUI hands these to `NSMenuItem.image`, which draws them in full colour.
- **Quick action for the open session.** A split toolbar item, right of the caffeine cup: the button opens the selected tab's working directory in the chosen app; the menu beside it is a picker — a checked list of the same icons that only changes which app the button uses. Picking never opens anything, and opening from an "Open In" menu never changes the pick, so each control does one thing. The pick persists in `UserDefaults` under `ClinicOpenInDefault` (so it is shared by every window and every instance of the app).
- **Toolbar, not the footer.** Both were built and tried side by side on 2026-09-08; the user chose the toolbar. The cost is that macOS draws toolbar item images desaturated (verified on macOS 26 — a colour app icon in a `ToolbarItem` menu label renders grey, and sibling views in that label are dropped), so the app reads as a grey silhouette there. The menu it drops down is a real NSMenu and keeps the icons' colour, which is where the choice is actually made.
- Scope is the *directory*. "Open in Ghostty" on a session row still means "resume this session in a standalone Ghostty window" and stays where it is.

## Consequences
- `OpenInMenu` is now a thin wrapper over the registry, so the sidebar and project menus stay in sync with the chip.
- A target that is uninstalled between refreshes falls back to the first target; a missing icon falls back to a text-only row.
