---
status: superseded by ADR-071 and ADR-121
date: 2026-09-07
tags: [adr, ui, sessions]
---
# ADR-032: New Session Flow

## Decision
'New session' asks for: project (existing, or a folder via NSOpenPanel), model (static aliases default/sonnet/opus/haiku plus free text), and a worktree toggle. The first prompt is typed in the terminal. Effort is left to the CLI default. Last choice is remembered per project.

## Consequences
- Launch command: `claude --session-id <uuid> [--model X] [-w] --settings <hooks-json>` typed via `initial_input` ([[ADR-016 Launch Shape]], [[ADR-017 Session Identity]]).
