---
status: accepted
date: 2026-09-10
amends: "[[ADR-077 Persistent Projects and Sidebar Polish]] (\"selection and hover fills stay full-width\" named a hover fill that never existed)"
tags: [adr, ui, sidebar, hover]
---
# ADR-110: Sidebar rows show hover

## Context
User (2026-09-10): *"the hover state on sessions is not visible in dark mode (or light mode even?)"*

It was not faint, it was absent. A `.sidebar` `List` on macOS draws a selection fill and nothing
for the pointer, and `SessionRow`'s `hovering` flag only swapped the trailing badges for the hover
actions ([[ADR-077 Persistent Projects and Sidebar Polish]]). On a row with no PR mark and no star
the badges column is empty, so hovering changed nothing but two small outline icons at the far
edge. ADR-077 says "selection and hover fills stay full-width". The hover half of that was never
built. Everything else in the sidebar that can be clicked (the nav rows, the toolbar buttons, the
project header's actions) does show the pointer.

## Decision
- **Session rows and the empty-project placeholder row draw a hover fill**: `.quaternary`, the
  same material as the nav rows' and toolbar buttons' hover, so the sidebar has one hover look.
- **It is the row's `listRowBackground`, inset to the selection fill's box.** Drawn there, it sits
  in the same cell the list's own selection occupies. `SidebarRowFill` holds the two numbers,
  **10 pt** horizontal inset and **8 pt** corner, and both were measured against the system
  selection fill in a screenshot: the left and right edges coincide to the pixel, and the corner
  profiles agree within one pixel. 6 pt was the first guess and visibly squarer than the selection.
- The row's hit area is its whole content rectangle (`contentShape`), so the fill does not flicker
  off over the gap between the title and the trailing actions.
- One modifier, `sidebarRowHover(_:)`, applies it to both row kinds.

## Consequences
- Verified in a smoke instance in dark and light (`-NSRequiresAquaSystemAppearance YES`): the
  hovered row's fill is visible in both, and sits beside a selected row without a seam or offset.
- If a future macOS changes the sidebar selection's inset or radius, `SidebarRowFill` is the one
  place to re-measure.
