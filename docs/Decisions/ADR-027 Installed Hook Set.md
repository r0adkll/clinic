---
status: accepted
date: 2026-09-07
tags: [adr, hooks]
---
# ADR-027: Installed Hook Set

## Decision
The injected `--settings` JSON registers, all `async: true`: SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PermissionDenied, Notification, Stop, StopFailure, PostModelSwitch, CwdChanged, WorktreeCreate, SessionEnd.
Not installed: PostToolUse and other per-tool events (high frequency, no state value).
When the debug preference is on, every payload is also appended to a per-session trace file.

## Consequences
- Hook command: `<bundle>/Contents/MacOS/clinic-hook` (exact location fixed in Architecture notes).
