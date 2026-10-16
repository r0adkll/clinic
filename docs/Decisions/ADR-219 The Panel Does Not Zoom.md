---
status: accepted (built 2026-10-15)
date: 2026-10-15
supersedes: "[[ADR-081 Files Panel Focus Modes]] (zooming the panel over the session)"
tags: [adr, ui, panel]
---
# ADR-219: The panel does not zoom

## Context
[[ADR-081 Files Panel Focus Modes]] let the right panel fill the tab, hiding the agent behind it (⌥⇧⌘J, a button in
the tab bar). [[ADR-212 A Session Is A Workspace Of Tabs]] kept it, moving the button into the main area's strip
and adding an unzoom to the panel's strip, because zooming hid the main strip. User (2026-10-15): *"With this new
panel/tab concept we don't really need the right panel full/expand/shrink action. It makes the UX a bit
confusing"*.

A view that wants the whole width can now be a tab in the main area, moved there by dragging
([[ADR-215 Tabs Move By Dragging]], [[ADR-218 A Tab Dropped On An Area Goes There]]) or by *Move to Main Area*.
Zoom was a third way of arranging the same panes.

## Decision
- **No zoom.** The main strip's zoom button, the panel strip's unzoom, *Panel ▸ Zoom Panel*, its rebindable chord
  (`zoomPanel`), the empty panel's *Zoom* hint, the `-ClinicZoomPanelAfterLaunch` seam, `SidePanel.isZoomed` and
  `TabContentView`'s zoom hosting are all removed.
- **The main strip's trailing end is the panel toggle alone.**

## Consequences
- A shortcut someone had rebound for *Zoom Panel* is ignored on load, since stored overrides are matched by name.
- Focus, occlusion and the drop zones lose their zoomed cases.
- ADR-081's other focus modes (the file tree toggle, pop-out file windows) are unaffected.
