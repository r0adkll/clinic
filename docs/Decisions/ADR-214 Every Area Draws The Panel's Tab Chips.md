---
status: accepted (built 2026-10-15)
date: 2026-10-15
supersedes: "[[ADR-212 A Session Is A Workspace Of Tabs]] (the main area's underlined tabs)"
amends: "[[ADR-172 The Empty Panel Offers Views With Reasons]] (its rows open into the panel)"
tags: [adr, ui, tabs, panel]
---
# ADR-214: Every area draws the panel's tab chips

## Context
Step 1 of [[ADR-212 A Session Is A Workspace Of Tabs]] gave the main area underlined tabs, from direction B on the
design canvas, while the right panel kept its chips ([[ADR-104 Panel Tabs Fit The Panel]]). User (2026-10-15):
*"The tabs are now weird and inconsistent. The main pane has odd, non-mac native type tabs. Both the main panel
the side (and future bottom) panels should use the old design for tabs. The empty panel UI's terminal action
also wouldn't open a new terminal, it just no-op'd on an existing terminal panel already being open."*

The empty panel's rows went through `showPane`, which fronts a view wherever it is open. With a terminal beside
Claude, *Terminal* fronted that one in the main area and left the panel empty, which looked like nothing.

## Decision
- **One strip, `PaneTabStrip(tab:area:)`, for every area**: the panel's chips and their adaptive forms (labelled,
  then glyph-only, then scrolling, ADR-104), with a `+` menu. A bottom area, if one comes, uses it too.
- **The main area's strip** pins a Claude chip first, in the same chip with the session's state glyph and no ✕.
  Its trailing end keeps the zoom and the panel toggle. The right panel's strip shows the unzoom while zoomed.
- **One chip.** `TabChipChrome` is the chip's fill, border, hover and size, used by the Claude chip and by every
  pane chip. A pane chip's move button points at the other area.
- **The `+` in either strip** adds to its own area. It lists that area's open tabs, then the other area's under
  *In the Right Panel* or *In the Main Area*.
- **The empty panel's rows open into the panel**, as its header says, through `addPane(area: .right)`. A shell or
  Files opens another beside one that is open in the main area. A pull request or a run already open in the main
  area is fronted there, since a session holds one of each.

## Consequences
- The underlined tab, `MainTabStrip` and `SidePanelTabBar` are gone.
- The strips are now identical, so the main area's tabs read as the same control as the panel's. The one
  exception is the pinned chip.
