---
status: accepted
date: 2026-09-07
tags: [adr, ui, sessions]
---
# ADR-037: Close Quit and Exited Flows

## Decision
- Closing a tab with a running Claude process: NSAlert sheet to confirm, then free the surface (kills the child).
- Quitting with running sessions: one NSAlert with the count.
- No 'keep running hidden' mode in milestone 1.
- When Claude exits and the shell remains, the tab enters `exited`; a 'Resume' button types the resume command via `ghostty_surface_text`; Cmd+W closes without a prompt.
