---
status: accepted
date: 2026-09-11
supersedes: the toolbar menus of ADR-078 (Open In), ADR-119 (caffeine) and ADR-122 (Run)
tags: [adr, ui, toolbar]
---
# ADR-123: Toolbar choices open in popovers

## Context
User (2026-09-11): *"the popup window for the run configurations when clicking the arrow in the
menu bar (and also for the caffeine and open with popups) are floating misaligned, vs having a
proper caret as part of the popup window like the notifications one. Can we fix / align these
popups?"*

The toolbar held two kinds of drop-down:
- **The bell** is a button with `.popover(arrowEdge: .bottom)`. Its history opens in a popover
  whose caret points at the bell.
- **Caffeine and Open In** were `Menu(primaryAction:)` items ([[ADR-119 Caffeine Persists And Can
  Wait For Agents]], [[ADR-078 Open In Targets and Quick Action]]). **The Run pill's chevron** was a
  borderless `Menu` ([[ADR-122 Projects Have Run Configurations]]). Each dropped a free-floating
  NSMenu that lined up with nothing.

## Decision
- **Every toolbar control with choices is a split button, and its choices open in a popover with
  a caret on the chevron.** `ToolbarSplitButton` is a plain button that acts, a divider, and a
  chevron button whose `.popover(arrowEdge: .bottom)` holds the choices. This is the bell's
  construction.
- **The popover content looks and behaves like a menu:**
  - `PopoverMenu`, with `PopoverMenuHeader`, `PopoverMenuNote` and `PopoverMenuDivider`.
  - `PopoverMenuRow` has a check column, an icon, a title, an optional monospaced subtitle and a
    trailing fact. The row under the pointer is highlighted with the accent, and a click performs
    the row and closes the popover.
- **What each control's choices do has not changed:**
  - **Caffeine**: the status line over the two modes. Choosing the checked mode turns caffeine
    off.
  - **Open In**: "Open with" and the apps, in colour. Choosing one only changes which app the
    button uses (ADR-078).
  - **Run**: the configurations, *Detected*, then the actions.
- **One list, two renderings.** `TabStore.runMenuEntries` builds the Run menu's lines once. The
  toolbar's `RunPopover` and the menu bar's native Run menu (`RunMenuItems`) both render them, so
  the two cannot drift. Menus in the menu bar stay NSMenus: that is what a menu bar is.
- **One glass capsule per control on macOS 26.**
  - **The problem.** Once caffeine and Run were plain buttons, macOS drew every adjacent item in
    one shared capsule, from New Session through Run.
  - **What didn't work.** `ToolbarSpacer(.fixed)` did not split it, whether inside an
    `if #available` or in a toolbar block typed for macOS 26.
  - **What does.** The three split controls use `.sharedBackgroundVisibility(.hidden)` and draw
    their own `.glassEffect(.regular.interactive(), in: Capsule())`, 36 pt high to match the
    native capsules.
  - **They share one toolbar item**, an `HStack`, rather than having one each. SwiftUI settles a
    toolbar's *items* on the first build: an item added later never appeared, and an item whose
    content went away held its width as a gap (both found 2026-09-11, from the user seeing a gap
    where the device capsule had been). Inside one item they are ordinary views that appear and
    collapse. The glass is applied per control inside it, so nothing draws an empty capsule.
  - **Before macOS 26** the toolbar keeps one item group and draws no capsules.

## Consequences
- **Keyboard.** The popovers lose the arrow-key navigation an NSMenu had. The bell's popover never
  had it either. The menu bar's Run menu keeps it, and ⌘R, ⌃⌘. and ⌃⌘R cover the common paths.
- **Colour.** Open In's app icons keep their colour in the popover, as they did in the NSMenu.
- **Refreshing.** The `.id` workaround that forced caffeine's toolbar menu to rebuild (ADR-119) is
  gone, because a popover's content is ordinary SwiftUI and re-renders.
- **Smoke key** (ADR-038): `-ClinicToolbarPopoverOnLaunch run|caffeine|openIn` opens that control's
  popover four seconds after launch.
- **Files.** `ToolbarPopover.swift` holds the split button and the popover rows. `RootView`'s
  toolbar is a `RootToolbar` modifier with a macOS 26 variant.
