---
status: accepted
date: 2026-09-07
tags: [adr, ui, lifecycle, milestone-4]
---
# ADR-069: Keep Running (hide window) and quit behaviour

## Context
Milestone 4 batch 8, the last management-parity item. Collins's close-window dialog has a third answer, Keep Running (Hide Window), which leaves every session untouched; a preference decides what quitting with running sessions does.

## Decision
- **Closing the window** (red button / ⌘⇧W) with running sessions offers **Keep Running** (hide the window; sessions, panels and scrollback stay), **Quit** (the usual graceful stops) and **Cancel**. Keep Running is the default when the menu bar icon is on. With nothing running the window just hides. The menu bar icon's Show Clinic, a notification, the dock icon or relaunching brings it back.
- **Quitting** (⌘Q) with running sessions consults the preference *When quitting with running sessions*: Ask (default), Quit (stop all gracefully and exit), Background all (send `/bg` to idle sessions, then exit), Hide window instead. The menu's Quit always shows the sheet under Ask; the status item's Quit really quits.
- Explicit Quit stops sessions gracefully with a bounded wait (5 s) before terminating.

## Consequences
- `applicationShouldHandleReopen` restores the window; `applicationShouldTerminate` implements the preference.
