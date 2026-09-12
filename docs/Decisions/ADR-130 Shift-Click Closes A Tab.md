---
status: accepted
date: 2026-09-11
supersedes: "[[ADR-079 Panel Tabs]] (closing the last pane left the panel open on an empty state)"
amends: "[[ADR-104 Panel Tabs Fit The Panel]] (a compact chip now has a pointer-driven close)"
tags: [adr, ui, tabs, panel]
---
# ADR-130: ⇧-click closes a tab

## Context
User (2026-09-11): *"It would be a nice shortcut that Shift + clicking on tabs just 'closes' them
(though for sessions we'll need to reconcile states or prompt to confirm. For the side panel we
should just close them. Then on the side panel if we close the last open one it should hide the side
panel. Additionally, shift clicking the toolbar of the sidepanel should hide it."*

Clinic has two tab strips — the session tab bar ([[ADR-049 Tab Bar]]) and the panel's
([[ADR-079 Panel Tabs]], sized by [[ADR-104 Panel Tabs Fit The Panel]]) — and in both, closing means
aiming at an ✕ that is a fraction of the chip and only there on hover. In the panel's **compact**
form ADR-104 removed the ✕ altogether ("where there is no room for a name there is no room for a
verb"), leaving the context menu, ⌘⌃W and the `+` menu as the only ways out; it rejected Safari's
hover-✕ because that "puts a destructive target under a pointer that came to select". A modifier has
no such problem: nothing changes under the pointer, and the gesture is deliberate.

## Decision

### ⇧-click a tab closes it, in both strips
The whole chip is the target, in the labelled form and the compact one. This is what closes the gap
ADR-104 left: a compact chip now has a pointer-driven close without growing a hover target.

**A session tab closes through `TabStore.close`, not around it.** [[ADR-037 Close Quit and Exited Flows]]'s
prompt — confirm, background, or close gracefully — still runs for a tab with Claude in it. The
modifier is a shortcut *to* the ✕, never past what the ✕ would have asked. A panel pane closes
outright: nothing is running in a pane that its tab does not already own.

### The panel goes with its last pane
`SidePanel.close` clears `isVisible` when the last pane leaves, superseding ADR-079's "closing the
last pane leaves the panel open on an empty state". Closing the thing you were reading is a request
for the session back, not for a column of chrome around nothing — and with ⇧-click that closing is
now a single gesture, so an empty panel would be what the shortcut mostly produced.

`SidePanelEmptyState` stays, and is still reachable the deliberate way: showing the panel (the tab
bar's chevron, ⌘⌥J) while nothing is open in it. What changes is that an empty panel is now only
ever asked for, never left behind.

### ⇧-click the panel's tab strip hides the panel
The same gesture aimed at the strip closes what the strip belongs to. A plain click on the bar goes
on doing nothing. It is *hide*, not toggle: the strip exists only while the panel shows, so a
⇧-click there can never bring it back. Hiding still has its own always-present control in the
session tab bar (ADR-079) — this is a second way to reach it from where the pointer already is.

### Read by `NSEvent.modifierFlags` inside the tap
`.onTapGesture` carries no modifiers, and SwiftUI's `TapGesture().modifiers(.shift)` would need the
plain tap to lose a priority race with it on every ordinary click. Reading `NSEvent.modifierFlags`
in the handler is what the codebase already does for ⌥ and ⌘ clicks elsewhere (`TaskDetail`,
`RunSheets`), and it keeps one gesture per chip.

### Where it stops
The sidebar, where ⇧-click is range selection ([[ADR-074 Sidebar Multi-Select]]). The shortcut is a
tab-strip gesture, not an application-wide one; a strip that is also a selection surface cannot have
both.

### Discoverability
The tooltips say so: the ✕'s help in both strips gains "or ⇧-click the tab", the compact chip's
tooltip becomes "*name* — ⇧-click to close", and the tab bar's hide button says "Hide the panel
(⌘⌥J), or ⇧-click its tab bar". No new menu items: these are pointer shortcuts for actions the
menus already carry.

## Consequences
- Middle-click to close is still not done (ADR-104's reason stands: SwiftUI has no middle-click
  gesture). ⇧-click is the cheap half of what that would have bought.
- `TabStore.hidePanel` joins `togglePanelVisibility` rather than reusing it, so the gesture can never
  toggle the panel *on* from a strip that is not on screen.
- Verified twice. First in a `swiftc` harness holding the chip-inside-a-strip structure copied from
  the source, logging each tap: a plain click selects, a ⇧-click on either chip closes, a ⇧-click on
  the bar hides, and a plain click on the bar is ignored — which also proves the strip's own gesture
  does not steal clicks from its chips. Then in a smoke instance (own `CLINIC_APP_SUPPORT`, a shell
  tab from `-ClinicOpenShellOnLaunch`, guarded `.cghidEventTap` clicks with `.maskShift`): ⇧-click on
  the strip hid the panel with its Terminal pane still open (footer chip outlined); ⇧-click on the
  lone chip closed the pane *and* hid the panel (footer chip plain); with two panes open, ⇧-click on
  one closed it and left the panel showing the other; ⇧-click on the shell tab closed it to the home
  screen.
