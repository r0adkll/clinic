---
status: accepted
date: 2026-09-07
tags: [adr, architecture, terminal]
---
# ADR-016: Launch Shape

## Context
A session surface can spawn the user's login shell and type the `claude` command via libghostty's `initial_input`, or set the surface `command` to `claude` directly with `wait_after_command`.

## Decision
Spawn the user's login shell; `initial_input` types the `claude` command. Plain shell tabs use the same path with empty `initial_input`.

## Consequences
- Aliases, PATH and env apply; the user lands in a shell when Claude exits.
- `claude` is resolved by the shell, so no CLI-path preference is needed.
- The typed command appears in shell history; accepted.
