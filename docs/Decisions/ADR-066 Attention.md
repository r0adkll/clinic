---
status: accepted
date: 2026-09-07
tags: [adr, notifications, ui, milestone-4]
---
# ADR-066: Attention — in-app cards, bells, history hygiene, update check

## Context
Milestone 4 batch 5 ([[Collins Feature Gap]]). Collins shows a slide-in card inside the window when you are in another tab, a desktop notification when away, nothing when you are looking at the session; terminal bells from other sessions become notifications; history rows can be removed; a daily update check announces a newer release.

## Decision
- **Delivery by focus** ([[ADR-033 Notification Delivery]] refined): app active and the session selected → history only; app active, another tab selected → an **in-app card** (top-right, project icon, title, two lines, click to go, × to dismiss, auto-hides after 8 s) plus the optional sound; app inactive → system notification as today.
- **Bells**: a `RING_BELL` action from a session or panel you are not looking at becomes a history row "Rang the bell" and follows the same delivery; the selected tab's bell stays the system beep. Coalesced per session within 5 s.
- **History**: per-row Remove and Mark read (context menu); archiving a session marks its rows read.
- **Update check**: once a day, `GET https://api.github.com/repos/r0adkll/clinic/releases/latest` (anonymous); when the tag is newer than `CFBundleShortVersionString` a history row and a card announce it once per version, linking to the release page. Preference to disable.

## Consequences
- `NotificationStore.Entry` gains `.bell` and `.update` kinds and a `url`.
- `TabStore.notify` becomes the single router for all attention events.
