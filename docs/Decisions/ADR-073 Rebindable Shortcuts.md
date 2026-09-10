---
status: accepted (supersedes the "hard-coded" clause of ADR-036)
date: 2026-09-08
tags: [adr, ui, milestone-3]
---
# ADR-073: Rebindable Shortcuts

## Context
[[ADR-036 Keyboard Shortcuts]] hard-coded the chords and deferred rebinding. Collins has a bindings editor.

## Decision
- Every menu command Clinic defines is a named `ShortcutAction` with a default chord; overrides live in `UserDefaults` (`ClinicShortcuts`, action → `"cmd+shift+n"`, empty = unbound). The chord grammar is a `KeyChord` in ClinicCore (parse/format/display, tested): modifiers `cmd`, `shift`, `opt`, `ctrl`; a printable key or a named key (`return`, `escape`, `tab`, `space`, `delete`, arrows, `home`/`end`/`pageup`/`pagedown`, `f1`–`f12`).
- Preferences → **Shortcuts**: one row per action with a recorder (click, press the chord; ⌫ clears, ⎋ cancels) and *Reset All*. A chord already used by another action is refused with the owner's name; ⌘Q and ⌘, are reserved.
- The menu is the single dispatcher: SwiftUI `Commands` read the store, so a change applies immediately. ⌘1…⌘9 tab jumps stay fixed.
- Inside a terminal, a chord that the user's Ghostty config binds wins (the surface consumes bindings before the menu, [[ADR-034 Ghostty Config Overrides and Shell Integration]]); Clinic does not add Ghostty unbinds for user chords.

## Consequences
- Adding a menu command means adding a `ShortcutAction` case; no literal chords in views.
