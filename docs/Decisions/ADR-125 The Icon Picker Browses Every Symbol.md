---
status: accepted
date: 2026-09-11
amends: ADR-122 (the editor's icon picker)
tags: [adr, ui, runs]
---
# ADR-125: The icon picker browses every symbol

## Context
User (2026-09-11), after Claude wrote Campfire's configurations: *"some added icons that are not
available (or were not linked to existing) icons in the configuration editor. Can we add more
options there (or some kind of glyph browser for options that can't all fit in the UI)"*

[[ADR-122 Projects Have Run Configurations]] gave the editor fifteen SF Symbols in a grid. Two
things go wrong with that, and both come from the same place: **Claude writes `run.json`**, so the
icon is whatever it reached for.
- **A real symbol that is not in the grid** (`wrench.and.screwdriver`) drew correctly everywhere,
  but the grid showed nothing selected, and picking any icon would have thrown it away.
- **A name that is not a symbol at all** (`android.robot`) drew nothing: an empty square in the
  toolbar, the menu and the pane.

**What the system has** (checked on this Mac, macOS 26.6): `CoreGlyphs.bundle` holds
`name_availability.plist` (9,184 symbols), `symbol_categories.plist`, `symbol_search.plist` (the
words the SF Symbols app searches), `symbol_order.plist` (its order) and
`symbol_restrictions.strings` (605 Apple marks). AppKit cannot enumerate symbols, but it can answer
whether one exists: `NSImage(systemSymbolName:)`. Clinic is not sandboxed, so it can read the
bundle.

## Decision
- **A name Clinic cannot draw falls back to the play glyph**, wherever a configuration's icon is
  drawn: the pill, the Run menus, the pane header, the editor and the picker. Nothing renders blank.
- **The toolbar pill wears the selected configuration's icon**, not a generic `▶`. User
  (2026-09-11): *"Lets use a run config's symbol in the menu bar pill instead of the run icon when
  its set"*. The icon says *what* ⌘R runs, next to its name; it is identity, so it is what the pill
  shows at rest. **Status still wins**: while the run goes the spinning arc replaces it, and its
  outcome is ✓, ✗ or a hollow ring ([[ADR-096 Session Status Indicators]]) — the pill never has to
  show two things at once. A configuration with no icon, or one this Mac cannot draw, keeps the play
  glyph by the same fallback, and *Set Up Run…* is still `▶` in secondary ink. This amends the
  toolbar button of [[ADR-122 Projects Have Run Configurations]].
- **The editor leads with the configuration's own icon**, whether or not it is a quick pick, so
  opening the editor cannot quietly lose it. Then two rows of quick picks — the things a project
  runs — then *Browse Symbols…*.
- **An unknown name says so** under the row: *"android.robot" isn't a symbol on this Mac, so the
  play glyph stands in. Browse for one, or type its exact name.*
- **The browser** is a sheet: a search field over every symbol, a category menu, a grid, and a field
  for an exact name. It is 820 pt wide and resizable; at 560 the buttons were squeezed against the
  style control.
  - **The grid lists subjects, not drawings** — one `hammer`, standing for `hammer.fill`,
    `hammer.circle` and `hammer.circle.fill` (7,266 drawings collapse to 4,184 subjects). The style
    below decides how they are all drawn and which drawing *Choose* returns; a subject this Mac does
    not draw that way keeps its plain form rather than leaving a hole.
  - **Search** matches the name and the system's own search terms, so *debug* finds `ladybug`.
  - **Order** is the system's, the SF Symbols app's: alphabetical opened on a wall of digits.
  - **Left out**: Apple's restricted marks (they may only stand for Apple's products) and the
    localized and right-to-left variants of drawings already listed. 7,266 of 9,184 remain here.
  - **Categories** are the system's subjects; its trait groups (multicolor, variable, indices) are
    not offered, since everything is in one.
  - **Typing a name** is always allowed, and the field says when this Mac has no such symbol.
    *Choose* is refused for a name that cannot be drawn.
- **Filled or outlined is a control, not a search.** A symbol's family — plain, filled, and the same
  in a circle or a square — is offered beside the icon, in the editor and in the browser's footer.
  User (2026-09-11): *"should we add a toggle (or dropdown if more than 2 options) for filled vs.
  outlined?"*
  - **In the editor**, where it is one configuration's icon: two ways (`globe`, `globe.fill`) is a
    *Filled* checkbox, more (`hammer` has four, `play` six) is a menu, and one is no control at all
    (`desktopcomputer`, `testtube.2`).
  - **In the browser** it is the style the whole grid is drawn in, so it is always the six-way menu.
  - **The pairs are the system's**, from `nofill_to_fill.strings`, because a filled name is not
    always `name + ".fill"`: `video.badge.checkmark` fills as `video.fill.badge.checkmark`.
  - **`.slash` and badges belong to the subject**, so `wifi.slash` offers only its filled twin, never
    plain `wifi`, which would mean the opposite.
  - **A trailing `.square` is only an enclosure when what is left is itself a symbol.**
    `square.and.arrow.up.on.square` is a subject; stripping it invented a name nothing draws, and
    those cells fell back to the play glyph (seen in the grid, 2026-09-11). Every family is now a
    symbol in its own right, which a test asserts over the real catalogue.
- **The set-up prompt** now tells Claude that `icon` is an SF Symbol name that exists on macOS, with
  examples, and that Clinic draws a play glyph for anything else.
- **Reading the system's catalogue is a convenience, not a dependency.** If a future macOS moves it,
  the suggested names stand in and typing a name still works.

## Consequences
- **ClinicCore `Run/SymbolCatalog.swift`** holds the catalogue: `make` (pure: filtering, ordering,
  the search index), `system()` (reads the plists), `symbols(matching:in:)` and the categories.
  `variants(of:)` builds a symbol's family from the system's fill pairs and the enclosures that
  exist. `SymbolCatalogTests` covers it, including tests against the real catalogue that skip
  themselves where the bundle is absent.
- **App `SymbolPicker.swift`** keeps only what needs AppKit: `exists` / `resolved` over
  `NSImage(systemSymbolName:)`, cached, and `SymbolBrowser`. `RunConfiguration.uiSymbol` is the
  fallback every call site draws.
- **Smoke key** (ADR-038): `-ClinicBrowseIconOnLaunch YES` opens the browser on the first
  configuration, which is a sheet inside a sheet and otherwise beyond a smoke run's reach.
- **Deferred**: the browser only picks symbols for run configurations; project icons (ADR-076) keep
  their own path. No recently-used row, and no multicolour or variable-value rendering.
