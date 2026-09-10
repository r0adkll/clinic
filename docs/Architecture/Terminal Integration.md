---
tags: [architecture, terminal, libghostty]
---
# Terminal integration

Decisions: [[ADR-008 libghostty Layer and Sourcing]], [[ADR-009 Terminal Configuration Source]], [[ADR-019 Window and Surface Lifetime]], [[ADR-034 Ghostty Config Overrides and Shell Integration]], [[ADR-035 Action Callback Scope]]. Facts: [[libghostty]].

## Contract between GhosttyBridge and the app
- `GhosttyConfig(loadUserDefaults:overrides:)` — loads `ghostty_config_load_default_files`, applies `GhosttyConfig.clinicOverrides`, finalizes. Diagnostics exposed as strings.
- `GhosttyRuntime(config:)` — exactly one per process; `ghostty_init` once; `wakeup_cb` re-dispatches `ghostty_app_tick` to main; `action_cb` → `GhosttyAction` to the target surface's delegate or `appActionHandler`; clipboard via `NSPasteboard`.
- `GhosttySurfaceView(runtime:options:)` — `NSView` + `NSTextInputClient`; options carry `working_directory`, `command`, `env_vars`, `initial_input`, `wait_after_command`. Forwards size, content scale, focus, occlusion, display id. `free()` is explicit and idempotent; never call libghostty from `deinit`.
- `GhosttyAction` — milestone 1 set (ADR-035) plus `.unhandled(kind:)`.

## Ownership
`Tab` owns its `GhosttySurfaceView` for life and a persistent `TabContentView` (AppKit `NSSplitView` tree: agent surface / shell panel / right page as an `NSHostingView`). SwiftUI never re-parents surfaces: `TabContentRepresentable` returns the tab's content view and only syncs panel and page state in `updateNSView`. `DetailView` mounts every open tab's representable and toggles opacity/hit-testing; `TabStore.applySelection` sets `isOccluded` on the others. (Earlier designs that re-parented surfaces through SwiftUI containers lost the surface when layouts changed.)

## Overrides (ADR-034)
Unbind keybinds whose action is: new_window, new_tab, close_surface, close_window, close_tab, quit, toggle_fullscreen, new_split, goto_split. Force `confirm-close-surface = false`. Shell integration comes from `/Applications/Ghostty.app` resources when present; nothing is bundled (GPLv3).
