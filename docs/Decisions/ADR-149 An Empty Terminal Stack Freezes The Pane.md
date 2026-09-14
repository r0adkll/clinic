---
status: accepted (built 2026-09-14)
date: 2026-09-14
amends: "[[ADR-019 Terminal Surface Ownership]] and [[ADR-072 Multiple Windows]] (the stack is mounted only while a live tab needs it)"
tags: [adr, ui, layout, swiftui, appkit, milestone-4]
---
# ADR-149: An empty terminal stack freezes the pane

## Context
User (2026-09-14): *"Small visual bug I noticed. On the empty screen, when I collapse the sidebar the
empty content is no longer centered."*

[[ADR-120 The Empty Screen Is A Home]] centres its column in the detail pane. Collapsing the sidebar
left that column centred on the pane's **previous** width — off by half the sidebar, ~180 pt on a
1800 pt window — and it stayed there: resizing the window did not correct it.

It does not reproduce on a window that has never held a tab, which is why the first several attempts to
see it failed. The precondition is that a tab has come and gone: launch, ⌘T, ⌘W, then collapse.

## Investigation
Geometry readouts printed on screen, one per container:

| | sidebar open | sidebar collapsed |
|---|---|---|
| `HomeScreen`'s `.frame(maxWidth: .infinity)` | w=1436 x=364 | w=1800 x=0 |
| the `ScrollView` inside it | w=1800 | w=1436 |

The frame tracked the pane. Its **content** did not: the subtree below it kept whatever width it was
given the first time the home screen was drawn after the last tab closed, in both directions — too
narrow when the sidebar collapsed, too wide when it opened again.

Three fixes aimed at the home screen all failed, and each failure was informative:
- Replacing the `GeometryReader` around the scroll view with `onGeometryChange` — no change, so the
  reader was a symptom, not the cause.
- `ViewThatFits(in: .vertical)`, drawing no scroll view when the column fits — no change, so the
  `ScrollView` was not the cause either.
- Sizing the column from a measured pane (`.frame(width: pane.width)`) — a feedback loop: measure,
  resize, measure, with the window visibly thrashing mid-animation.

What the three had in common is that they all tried to fix the frozen subtree from inside it. The
freeze is imposed from outside: `HomeScreen` shares a `ZStack` with `TerminalStack`, the
`NSViewRepresentable` hosting this window's tab content views. Once that view has hosted a tab and been
emptied again, it stops the stack's children from being re-proposed a new width.

## Options
1. **`sizeThatFits` on the representable**, returning the proposal. Made it worse: the proposal a
   representable is handed there is the window's width, not the pane's, so the column centred 180 pt to
   the right instead.
2. **`.frame(maxWidth: .infinity, maxHeight: .infinity)` on the representable.** No effect — the stack
   was already being told to fill; the problem is what it does to its siblings.
3. **Mount the stack only while a live tab needs it.** Chosen.

## Decision
- **`TerminalStack` is in the `ZStack` only when this window has a live tab.** With none there is
  nothing to keep mounted — the invariant ADR-019 and ADR-072 protect is that a *live tab's* surface
  survives being switched away from, and an empty stack protects nothing.
- Content views are owned by their `Tab`, not by the stack, so tearing the stack down and building it
  again on the next ⌘T re-parents rather than recreates. A tab moved between windows is unaffected: the
  adopting window's `sync` calls `addSubview`, which re-parents it whichever window SwiftUI updates
  first — the case the existing comment on `TerminalStackView.sync` already covers.
- The home screen itself is untouched. Its `GeometryReader`, its `ScrollView` and its 640 pt column all
  stay as ADR-120 wrote them.

## Consequences
- The empty screen is centred in the pane in both sidebar states, across repeated toggles, whether or
  not a tab has been open. Verified by measuring the rendered pixels: content centre equals pane centre.
- *A frozen SwiftUI layout is usually frozen by a sibling, not by itself.* Three fixes inside
  `HomeScreen` failed before the readouts placed the boundary above it. Print the geometry of each
  container before changing any of them.
- Any future screen sharing that `ZStack` inherits the fix; `AutomationsScreen` is the other branch
  there without an explicit fill frame.
