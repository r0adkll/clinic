---
status: accepted
date: 2026-09-07
tags: [adr, ui, notifications]
---
# ADR-033: Notification Delivery

## Decision
On entering `waitingForPermission`, `waitingForInput`, or the working→idle edge: post a UNUserNotificationCenter notification only if the app is not frontmost or the session is not the selected tab. Dock badge = count of sessions with `unread` or a waiting state. Clicking a notification activates the app and selects the session. No sound by default. Per-session mute and a global toggle are milestone 2.

## Consequences
- Notification permission is requested on first launch.
