---
status: accepted
date: 2026-09-26
amends: "[[ADR-034 Ghostty Config Overrides and Shell Integration]] (what is unbound), [[ADR-073 Rebindable Shortcuts]] (which terminal bindings win)"
tags: [adr, keyboard, terminal, ghostty]
---
# ADR-173: Clinic's chords outrank Ghostty's defaults

## Context
User (2026-09-26), after [[ADR-172 The Empty Panel Offers Views With Reasons]] put *Zoom ⌥⇧⌘J* on
screen: *"The 'Shrink' shortcut doesn't do anything and I think an OS default is catching it instead."*

It was not macOS. `GhosttySurfaceView.performKeyEquivalent` offers a key to the surface's keybinds
before the menu sees it, and libghostty's defaults bind `super+alt+shift+j` to
`write_screen_file:open`, which writes the screen to a temporary file and opens it in the default app.
Whenever a terminal had the keyboard, Zoom Panel never reached its menu item.

ADR-034 only unbinds the window, tab, split and quit actions. Ghostty v1.3.1's macOS defaults collide
with six of Clinic's default chords:

| Chord | Clinic | Ghostty default |
|---|---|---|
| ⌥⇧⌘J | Zoom Panel | `write_screen_file:open` |
| ⇧⌘P | Pull Request Panel Tab | `toggle_command_palette` |
| ⌘K | Jump to Session | `clear_screen` (performable) |
| ⌘J | Terminal Panel Tab | `scroll_to_selection` (performable) |
| ⇧⌘G | Diff Panel Tab | `navigate_search:previous` (performable) |
| ⇧⌘Z | Undo Archive | `redo` (performable) |

ADR-073 said that inside a terminal "a chord that the user's Ghostty config binds wins". That rule is
about bindings the user chose. These are Ghostty's defaults, which nobody chose over Clinic's menu, and
the menu advertised a chord that did something else.

## Decision
- **Clinic unbinds the triggers of its own chords, not their actions, before the user's Ghostty files
  load.** `GhosttyConfig` takes `yieldTriggers` and loads `keybind = <trigger>=unbind` for each one right
  after `ghostty_config_new`. Loading order becomes: defaults, then Clinic's yields, then the user's
  files, then the ADR-034 unbinds and overrides, then finalize.
  - Ghostty's defaults lose the chord, so the menu gets it.
  - A binding in the user's own config loads later and wins, so ADR-073's rule still holds for bindings
    the user chose.
  - Unbinding by trigger leaves the action bound to any other key: ⌃⇧⌘J still copies the screen, and a
    `clear_screen` the user bound elsewhere keeps working.
- **The triggers are every bound chord, rebinds included.** `KeyBindings.ghosttyTriggers` spells each
  `KeyChord` in Ghostty's grammar (`ctrl`/`alt`/`shift`/`super`, `enter`, `backspace`, `arrow_*`,
  `page_*`, `plus`). `=` and `>` are skipped because the grammar cannot spell them.
- **A rebind applies at once.** `KeyBindings.onChange` makes `TabStore.reloadGhosttyKeybinds` build a
  fresh config and hand it to `ghostty_app_update_config`, which sends every open surface a
  `change_config`. It re-reads the user's Ghostty files, as Ghostty's own *Reload Configuration* does.

## Consequences
- **⌘K in a terminal opens Jump to Session instead of clearing the screen**, as the menu says it does.
  Anyone who wants the clear back can bind `super+k=clear_screen` in their Ghostty config, and that wins.
  The same goes for ⌘J, ⇧⌘G and ⇧⌘Z.
- Chords Clinic handles through Ghostty actions today (⇧⌘[ / ⇧⌘] as `previous_tab` / `next_tab`) now
  arrive through the menu instead, which runs the same commands.
- `ghostty_config_trigger` does not report `performable` bindings, so the config alone cannot show
  whether ⌘K and the others are bound. The test asks a live surface instead.
- Verified in `GhosttyBridgeTests`, against the pinned libghostty:
  - A surface reports all six chords as bindings, and after `reloadConfig` with the yields it reports
    none of them, while ⌘C is still a binding. The reload happens after the surface exists, which is the
    rebind path.
  - A `super+k=clear_screen` binding loaded after the yield takes ⌘K back.

  `make build` succeeds. Not run: pressing ⌥⇧⌘J in a live terminal.
