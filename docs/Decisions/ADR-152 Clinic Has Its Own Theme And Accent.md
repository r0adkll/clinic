---
status: accepted (built 2026-09-14)
date: 2026-09-14
amends: "[[ADR-108 The Settings Window Is A Source List]] (a seventh pane), [[ADR-111 Nav Rows Wear Accent Tiles]] and every ADR that draws with the accent (what *the accent* now means)"
tags: [adr, ui, settings, appearance, accent, theme]
---
# ADR-152: Clinic has its own theme and accent

## Context
User (2026-09-14): *"Lets add some 'Appearance' settings that lets the user override the accent color
and theme modes (light/dark/system)."*

Until now Clinic had neither. Every window took the Mac's appearance, and the ~110 places that draw
with the accent — the tiles of [[ADR-108 The Settings Window Is A Source List]] and [[ADR-111 Nav Rows
Wear Accent Tiles]], selection fills, the caffeine capsule's wash, links, progress — read
`Color.accentColor`, which is the Mac's accent. That is the right default and stays the default; the
request is for a per-app override of both, the way Ghostty, Xcode and most editors offer one.

## What macOS actually offers
Checked on macOS 26 with small `swiftc` harnesses and then in the real app, because the documented
routes and the working ones are not the same set:

| Mechanism | `Color.accentColor` (SwiftUI) | SwiftUI controls | AppKit controls | Live? |
|---|---|---|---|---|
| `.tint(_:)` at the root | no | yes (pickers, prominent buttons) | no | yes |
| `.accentColor(_:)` (deprecated) at the root | **no in a real window** (yes under `ImageRenderer`) | yes | no | — |
| Asset-catalog `AccentColor` | yes | yes | yes | no — compiled in |
| `AppleAccentColor` in the app's own defaults domain | yes | yes | yes | at launch, and again on the distributed **`AppleAquaColorVariantChanged`** — not on `AppleColorPreferencesChangedNotification` or `AppleInterfaceThemeChangedNotification`, which System Settings sends alongside it |

So there is no single call that changes the accent everywhere at once. Two things together cover it.

## Decision

### An Appearance pane, second in the source list
*Theme* — System / Light / Dark as a segmented control — and *Accent colour* — a row of swatches: the
Mac's own (ringed, so it is told apart from a named accent of the same colour), System Settings' eight
in System Settings' order, and a colour well for anything else. The chosen swatch carries a white dot
and a ring of its own colour. It sits between General and Sessions: it is about the whole app, not one
subject, and it is the pane a new user goes looking for. Glyph `paintpalette`, outline like the rest.

Both preferences live on `Appearance.shared` (`ClinicTheme`, `ClinicAccent` in UserDefaults) rather
than in `@AppStorage`, because changing either has work to do beyond storing it.

### Theme is the app's `NSAppearance`
`NSApp.appearance = NSAppearance(named: .aqua / .darkAqua)`, or nil for System. Every window, sheet,
popover and AppKit control follows at once, and so does every `@Environment(\.colorScheme)` read (the
GitHub-rendered bodies, the diff text view). Verified: a smoke instance launched with `-ClinicTheme
light` came up light on a dark Mac, and pressing *Light* in a dark instance switched both open windows.

**The terminal follows too.** `Appearance` observes `NSApp.effectiveAppearance` and tells libghostty
(`ghostty_app_set_color_scheme`), which nothing did before. A Ghostty config with `theme =
light:…,dark:…` then asks for a soft config reload, which `TabStore` now answers by handing the runtime
its current config back — the way Ghostty's own app does — so the conditional theme is re-evaluated.
The files are not re-read. A config with one theme sees no change.

### Accent is a Clinic colour, plus a per-app default for AppKit
**`Color.accent` replaces `Color.accentColor` at every call site** (105 `Color.accentColor` and five
shorthand `.accentColor`). It is a `@MainActor` static on `Color` that reads `Appearance.shared`, so a
view body that uses it is tracked by Observation and redraws when the accent changes; when following
the system it returns `.accentColor`, which is then the Mac's. This is the *only* way the tiles, fills,
links and washes change live — the table above is why. New code draws with `Color.accent`;
`Color.accentColor` is now a bug.

**`.tint(Appearance.accentColor)` goes on every SwiftUI root** — the two scenes, the file and image
windows, and each `NSHostingView` the side panel builds (chrome, page, header, footer), because the
environment does not cross from one hosting root to another. That is what turns the segmented picker,
prominent buttons and progress bars.

**AppKit-drawn controls follow through the per-app default and a nudge.** Switches, checkboxes, radio
buttons and list selection fills — the sidebar's selected row included — read
`NSColor.controlAccentColor`, which AppKit resolves from the app's own `AppleAccentColor` default: the
same key System Settings writes globally, and the documented per-app override (`defaults write
com.r0adkll.clinic AppleAccentColor 5`). Choosing a named accent writes that key into Clinic's domain;
System removes it; a custom colour writes the **nearest of the eight**, so a switch is at least in the
same family as the colour the rest of the window wears, and the footer names which one.

AppKit reads that key at launch, and a first draft of this ADR said "read once", so the footer promised
switches at the next launch. User: *"looks like the sidebar item highlights are still the system
accent"*. It reads it again on **`AppleAquaColorVariantChanged`**, the distributed notification System
Settings sends when the Mac's accent changes, so `applyAccentDefault` posts it (`deliverImmediately`)
after writing the key, and `controlAccentColor`, `selectedContentBackgroundColor` and
`keyboardFocusIndicatorColor` all change in-process — measured in a harness for a named accent,
graphite and removal, and seen in the live app's sidebar selection. The first probe posted
`AppleColorPreferencesChangedNotification`, which is the obvious name and does nothing; a later one
posted all three System Settings sends and worked, and isolating them found the one that matters. The
notification is system-wide: every app hears it and re-reads an accent that, for them, is unchanged.

The three AppKit sites that drew with `controlAccentColor` directly — the diff hunk band, the shortcut
recorder, the caffeine cup — now read `Appearance.shared.nsAccentColor`, so they are live as well.

**The System swatch shows the Mac's accent, not `controlAccentColor`.** Once the app has written its
own `AppleAccentColor`, `controlAccentColor` answers with *that*; the Mac's is read from the global
defaults domain (nothing stored means Multicolour, drawn as blue).

### Custom colours are set when the picker settles
The colour well binds to a `@State` copy and writes the accent on change, so dragging in the picker
does not write a preference per pixel; a custom colour is stored as `#RRGGBB`. The well carries a small
check in the accent when it is the chosen one, since a well has no ring to give.

## Consequences
- `Appearance.swift` is the model, the `Color.accent` token, and the `clinicAppearance()` root
  modifier. `Prefs.theme` / `Prefs.accent` are the keys.
- `-ClinicPreferencesTab appearance` opens the pane; `-ClinicAccent purple|#1ABC9C` and `-ClinicTheme
  light|dark` seed a smoke instance through the argument domain. **A smoke instance writes (or removes)
  `AppleAccentColor` in the real `com.r0adkll.clinic` domain the moment it starts and posts the
  notification**, so the live app's switches and selection fills take the smoke run's accent at once
  ([[ADR-038 Preferences and Diagnostics]]' shared-defaults caveat, now with an immediate effect).
  Quit the smoke instance, wait for it to flush, then delete `ClinicAccent`, `ClinicTheme` and
  `AppleAccentColor` — or restore the reader's — and check the domain again.
- Two `@MainActor` annotations landed on colour helpers that used to be nonisolated
  (`UsageSnapshot.Bar.tint`, the grill pane's pip fill), because `Color.accent` is main-actor.
- The status item's caffeine glyph is drawn when its state changes, so a new accent reaches it at the
  next change rather than instantly. Acceptable; noted.
- ADR-111's rule that the tile is *the accent* and never a colour of its own still holds — the accent is
  now just Clinic's rather than necessarily the Mac's.

**Verified** in a smoke instance on a red-accent, dark Mac (the SwiftUI side), then the AppKit side in a
`swiftc` harness and in the live app: launched with a custom teal and dark, every
tile, link, the picker and the caffeine cup teal, the System swatch red; *Blue* pressed through the
accessibility API turned all of them blue in both windows with `ClinicAccent = blue` and
`AppleAccentColor = 4` read back; *Light* pressed turned both windows light. Earlier runs are what
produced the table: with only the root modifiers, the tiles stayed on the launch default while the
picker changed. `xcodebuild` Debug clean apart from a pre-existing warning in `EditorPanel.swift`.
