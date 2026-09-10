---
status: accepted
date: 2026-09-07
tags: [adr, architecture, sessions, hooks]
---
# ADR-026: Session State Machine

## Context
Hooks ([[Claude Code Hooks and Transcripts]]) give reliable lifecycle events; Collins infers state from the screen. Clinic needs a small explicit machine.

## Decision
States for an open session:
- `launching` — surface spawned, no `SessionStart` yet
- `idle` — Claude at the prompt, nothing pending
- `working` — from `UserPromptSubmit` until `Stop`
- `waitingForPermission` — `PermissionRequest` until `PreToolUse`, `PermissionDenied` or `UserPromptSubmit`
- `waitingForInput` — `Notification` of type `idle_prompt`, `elicitation_dialog` or `elicitation_url_dialog` until `UserPromptSubmit`
- `exited` — `SessionEnd`, or the surface reports the child gone
`StopFailure` → `idle` with an error badge. Orthogonal `unread` flag: set on the working→idle edge when the session is not the selected tab of a frontmost window; cleared on selection.
Sessions not open in Clinic have no state, only last activity (transcript mtime).
libghostty's `PROGRESS_REPORT` action is a corroborating signal only, never a state source.

## Consequences
- The machine is a pure value type in ClinicCore with exhaustive tests over hook sequences.
- Sidebar and notifications consume state transitions, not raw hooks.
