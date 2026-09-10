---
status: accepted
date: 2026-09-07
tags: [adr, ui, milestone-4]
---
# ADR-067: Menu bar status item

## Context
Milestone 4 batch 6. Collins keeps a tray icon that shows working/unread/idle at a glance, wears the unread count, and lists open sessions to jump to.

## Decision
- An `NSStatusItem` (SF Symbol, template) whose symbol reflects the app: **working** (`circle.dotted` filled) while any tab is working, **unread** (`bell.badge`) while anything is unread or waiting, **idle** (`circle`) otherwise; the unread count is drawn as the item's title.
- Menu: one row per open session tab (state glyph + title; click reveals it), a separator, "Show Clinic", "New Session…", "Quit Clinic" (really quits).
- Preference "Show menu bar icon" (on). The dock badge stays independent.

## Consequences
- macOS hides status items that do not fit (including the notch region on MacBooks with a full menu bar); the dock badge and the bell remain the fallbacks.
- `StatusItemController` observes `TabStore` and `NotificationStore` through `withObservationTracking` re-armed on each change.
