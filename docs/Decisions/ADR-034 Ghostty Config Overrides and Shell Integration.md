---
status: accepted
date: 2026-09-07
tags: [adr, terminal, libghostty]
---
# ADR-034: Ghostty Config Overrides and Shell Integration

## Decision
After loading the user's Ghostty config, Clinic unbinds every keybind whose action is one of: new_window, new_tab, close_surface, close_window, close_tab, quit, toggle_fullscreen, new_split, goto_split. It forces `confirm-close-surface = false` so Clinic's own close flow runs.
Shell integration: Ghostty's scripts are GPLv3 and are not bundled. If `/Applications/Ghostty.app` exists, point the resources dir at its bundled scripts at runtime; otherwise run without shell integration. Nothing in milestone 1 depends on it.

## Consequences
- The override list is the single source in GhosttyBridge and is documented in Architecture.
