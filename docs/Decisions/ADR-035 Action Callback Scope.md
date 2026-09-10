---
status: accepted
date: 2026-09-07
tags: [adr, terminal, libghostty]
---
# ADR-035: Action Callback Scope

## Decision
Milestone 1 handles: set_title, pwd, ring_bell, progress_report, command_finished, mouse_shape, open_url, clipboard read/write callbacks, close_surface, color_scheme, quit. New tab, window and split requests map to 'new shell tab in the current project'. Everything else returns false and is logged once per kind.

## Consequences
- The action switch lives in GhosttyBridge and emits typed Swift events to the app.
