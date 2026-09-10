---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-081 Files Panel Focus Modes]] (header layout only)"
tags: [adr, editor, diff, github, ui, panel]
---
# ADR-102: One chrome for every file browser

## Context
User (2026-09-10): *"Can we apply the same visual improvements to the files / editor panes. These
share similar layouts and should share or be as similar as possible for their features."*

Three panes now show a file list beside a detail view: the Files panel ([[ADR-057 Editor Panel]],
[[ADR-081 Files Panel Focus Modes]]), the pull request panel's Files tab
([[ADR-091 Pull Request Panel Tabs and Files Tree]]) and the Diff panel
([[ADR-101 Diff Panel Is List-Then-Detail]]). Their *rows* were unified by
[[ADR-099 File Tree Rows Are Full-Width Controls]]; everything around the rows had drifted:

| | Files panel | Diff / PR browser |
|---|---|---|
| list header | no material, project name + two icon buttons | `.bar`, toggle + filter |
| detail header | `.bar`, 30 pt | `.bar`, 28 pt |
| tree toggle | in the *detail* header, so it sits mid-pane when the list is open | pane's top-left in both states |
| seam | `TreeResizeHandle`, clamped, `.pointerStyle` | `TreeDivider`, unclamped, `NSCursor` on hover |
| filtering the list | Quick Open, a 560 pt sheet | a field in the list's own header |

Two headers of different heights and materials, side by side, is the thing that reads as unfinished:
the two columns stop looking like two columns of one pane.

## Decision
One chrome, in `PaneChrome.swift`, used by all three:

- **`PaneHeader`** — a column's header: 28 pt, `.bar`, the same padding, with a divider beneath.
  Every column of every browser uses it, so the two headers of a pane are one band.
- **`TreeToggleButton`** at the pane's **top-left in both states**: in the list's header when the
  list is open, in the detail header when it is not. It keeps ADR-081's rule (the toggle can never
  hide itself) and adds a stronger one — it does not move when the list opens.
- **`TreeFilterField`** in every list header, with its `matches/total` count inside the field.
- **`TreeSplitHandle`** — one seam: clamped, `.pointerStyle(.columnResize)`, dragged in global
  coordinates (a local translation chases the pointer, [[ADR-081 Files Panel Focus Modes]]), and
  committing its width only when the drag ends, so a preference is not written many times a second.
  It is **one point of layout** — a line the two columns meet at, with the grab area as a wider
  overlay that takes no width. The 9 pt strip it replaced put the pane's own background between two
  columns that each paint their own, which read as a seam that had come apart.

**The Files panel's tree gains the inline filter**, ranked with the same `FuzzyMatcher` as Quick Open
and the other two browsers — a tree while browsing, a ranked flat list while filtering. Quick Open
(⌘⇧O) stays: it is the fast path from the keyboard and works with the tree hidden, and its button
moves to the header's trailing actions where the other verbs are.

**The project name leaves the Files tree header** to make room. The pane's own tab chip and the
window footer both name the project already — the same argument ADR-080 used for keeping the branch
out of the diff header.

### What stays different
Only what the features genuinely differ on: the Files pane keeps Show Hidden, Collapse All, the agent
files section and its editing verbs (Revert, Save, pop-out, Reveal); the diff browsers keep the file
status chip and the `+n −n` counts. Nothing that both panes do is done two ways.

### Dragging is live
The column reads the width the drag is *moving*, and the stored width is written once when the drag
ends. Reading the stored width instead — which the Diff panel did first — means nothing moves until
the drag finishes and the column then jumps to its new size.

## Consequences
- `TreeDivider` and `TreeResizeHandle` collapse into `TreeSplitHandle`; the Diff panel's seam gains
  the clamping and commit-on-end behaviour it did not have.
- The Files pane's tree column now filters without a sheet, which is the shortest path to "show me
  the files whose name contains X" while reading.
- A fourth browser gets its chrome by using `PaneHeader`, not by copying a header.
