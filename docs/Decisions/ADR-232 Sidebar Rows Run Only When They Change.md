---
status: accepted (built 2026-11-01)
date: 2026-11-01
amends: "[[ADR-074 Sidebar Multi-Select]] (a row's checkbox toggles the window's selection itself) and [[ADR-156 Sessions Can Be Cards]] (a card's slot is compared before it runs)"
tags: [adr, ui, sidebar, bug, diagnostics]
---
# ADR-232: Sidebar rows run only when they change

## Context
Installed 0.6.1 died on 2026-10-31 at 08:24 with the layout loop's exception, the sixth time. This time
[[ADR-231 Layout Loops Are Witnessed And Releases Keep Their Symbols]]'s witness was running. The fatal loop and
three the app survived (10-28, 10-30 twice) all recorded the same things:
- **No observed value changed on any pass.**
- **None of Clinic's toolbar, header, root, detail or footer views ran.** Toolbar widths, the first responder and
  the window frame held still.
- **The only Clinic body that ran was `SessionCard`.** Every visible card ran once per full render, about every
  38 ms, with two cheap passes between renders. The sidebar's own body did not run.
- **The selected session was idle in two of the four.**

The 0.6.1 dSYM symbolicated the only Clinic frames in the stacks. They were `main` and the witness's own counting
method.

AppKit's display-cycle trace, with a disassembly of SwiftUI on macOS 26.6.2, gave the loop:
1. The root `NSHostingView` renders and its preferences change.
2. `AppKitToolbarStrategy.willReturnUpdates` compares the window's `FocusedValueList.version` with the last one it
   saw.
3. On any difference, `Toolbar.LocationStorage.updatedVendedItems(newFocusedValues:)` hands every toolbar item's
   hosting view the focused values. It calls `invalidateProperties(.focusedValues, mayDeferUpdate: true)` with no
   equality check, which dirties the window again in the same display-cycle flush.

The loop therefore lasts as long as every render re-versions the focused-value list. Clinic declares no focused
values, so the contributors are SwiftUI's own, in the sidebar's `List`. The cards running inside that `List` on
every render, with nothing changed, were the one piece of Clinic in the cycle.

They ran because `SessionCardSlot`, `SessionCard` and `SessionRow` each stored select mode's `onToggle` closure.
SwiftUI cannot compare a closure, so it treats every row the list hands back as changed. A standalone program on
macOS 26 measured it. In a sidebar `List` of 10 rows, re-rendering the parent 10 times ran the closure rows 100 times
and the closure-free or `.equatable()` rows 0 times. One change to a value an equatable row read still ran all 10.

User, of the proposals (make the rows cheap to hand back, a brake, an AppKit toolbar): *"lets do the first item"*.

## Options
1. **Rows that compare.** Take the closure out of the rows and compare a slot's inputs before its body runs.
   This is cheap and keeps behaviour as it is. It removes the only Clinic work in the cycle and the changing row
   outputs that re-version the focused values. It is not proven to end the loop: that needs the loop to recur
   without cards in its record.
2. **The brake** ADR-231 deferred. It stops the crash and hides the cause.
3. **An AppKit `NSToolbar`** whose items host Clinic's own views, bypassing SwiftUI's `ToolbarBridge`. This is the
   structural fix, and a large change to ADR-212's header.

## Decision
Option 1.
- **`SessionSelectBox`** is select mode's checkbox for the card and the compact row. It toggles
  `window.bulkSelection` itself from `WindowState` in the environment, so no row takes an action from the sidebar.
  It is labelled *Selected* or *Not selected* for VoiceOver.
- **`SessionCardSlot` and `SessionRow` are `Equatable`.** They compare the summary, the tab by identity, the
  style, the path setting, selection, checked state and lineage. The sidebar applies `.equatable()` to both. The
  stores they read still re-run them through observation; only a row handed back unchanged is skipped.
  `SessionCard` itself stays non-equatable: its content carries actions, and it now runs only when its slot does.
- **The card's age ticks by itself**, in a `TimelineView(.everyMinute)`. *now*, *4m* and *3h* were strings worked
  out when the card ran, and they stayed current only because the card ran on every sidebar render. Nothing else on
  a card depends on the clock: a child's timer is `Text(_:style: .timer)`, which updates itself, and a terminal's
  foreground job has the slot's existing three-second `TimelineView`.
- **The witness notes `SessionCardSlot`** as well as `SessionCard`. Cards without their slot in a future record
  mean the card's own observed values changed. A slot that runs means one of its stores did, or a hand-back got
  through the comparison.

## Consequences
- **Checked in Clinic Dev** with a temporary probe write that flipped `ClinicShowUsage` on each pass, so the sidebar
  handed its rows back unchanged, on Cards style:
  - before the change: `Sidebar` 204, `SessionCard` 204;
  - after it: `Sidebar` 204, no card or slot.
- **Select mode, driven by accessibility** in Clinic Dev: turning select mode on showed one *Not selected* box.
  Pressing it made it *Selected*, pressing again cleared it, and *Done selecting* removed it.
- The age's minute tick was built but not watched in the app.
- **Not known: whether the loop is gone.** The next loop file says. If it recurs with no cards and no slot in its
  record, the focused-value list is re-versioned elsewhere in the sidebar (`List(selection:)`,
  `contextMenu(forSelectionType:)`, `onExitCommand`, `searchable`), and Option 2 or 3 is next.
- A new stored property on either row must join its `==`, or the row will miss changes to it. A closure stored on
  a row brings back the old behaviour silently.
