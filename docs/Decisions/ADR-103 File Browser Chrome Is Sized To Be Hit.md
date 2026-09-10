---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-102 One Chrome For Every File Browser]] (metrics only), [[ADR-099 File Tree Rows Are Full-Width Controls]] (row metrics only)"
tags: [adr, editor, diff, github, ui, panel]
---
# ADR-103: The file browser's chrome is sized to be hit, not just to fit

## Context
User (2026-09-10): *"The UI for the files/diff file tree (collapse/expand action, filter box, etc)
are a bit too small and difficult to see sizing wise. Can we improve the UI/UX here?"*

[[ADR-102 One Chrome For Every File Browser]] made the three file browsers share one chrome, and
[[ADR-099 File Tree Rows Are Full-Width Controls]] made their rows share one row. Both settled
*which* controls exist and *where*; neither one sized them, and every part of that chrome had
inherited the panel's caption scale:

| | was | why it read as too small |
|---|---|---|
| header band | 28 pt with `.controlSize(.small)` | leaves ~20 pt for a control, so nothing in it could be a proper target |
| header icon buttons | bare `Image` in a `.borderless` `Button` | hit-tests **as the glyph** — about 14 × 14 pt, with no fill to say it is a button at all |
| icon glyphs | `.controlSize(.small)`'s default, ~11 pt | thin line art (`eye.slash`, the collapse arrows) at 11 pt is decoration |
| filter field | `.caption` text, 2 pt of vertical padding | on macOS `.caption` is **10 pt**; the field was a ~17 pt tinted sliver, and its `.plain` text field takes clicks only on the text |
| `matches/total` | `.caption2` tertiary | the count the field exists to give you was its least legible element |
| row name | 12 pt in a 24 pt row | macOS source lists use 13 |
| chevron | 9 pt in a 12 pt column | a tick, not a shape |
| `+n −n`, status chip, `A`/`D` badge | `.caption` / `.caption2` | 10 pt for the numbers the diff header exists to show |

The through-line: sizes were chosen to *fit* a 380 pt panel column, and a control small enough to fit
is not automatically large enough to see or to hit.

## Decision
Everything is sized from the target, not from the leftover space. In `PaneChrome.swift` and
`FileTreeRowView.swift`, so all four browsers move together.

### A header holds controls, so it is control-sized
`PaneMetrics.headerHeight` 28 → **34**, and `.controlSize(.small)` comes off both headers. The band
is now tall enough for a 24 pt control with breathing room, which is what makes it read as chrome
over the list rather than as the list's first row.

### `PaneIconButton` — one shape for every header verb
A **24 × 24 pt** target with a **14 pt** glyph and a rounded fill of its own: nothing on hover,
`primary` at 0.09 hovering, accent at 0.11 when the verb is *on*. It is the same rounded-rectangle
language `FileTreeRowView` uses, so a header button and a row highlight the same way.

The old shape — a bare `Image` in a `.borderless` `Button` — hit-tests as the glyph and nothing else.
That is the header's version of the fault ADR-099 fixed in the rows: **what looks clickable was not
what was clickable.** Every verb takes this shape: the tree toggle, Collapse All, Show Hidden, Quick
Open, pop-out, Reveal in Finder. Text buttons (Revert, Save) stay text buttons at their regular size.

Show Hidden also **changes its symbol** (`eye` / `eye.slash`) rather than only its tint, so its state
survives being read at a glance, or by someone who cannot separate the accent colour from grey.

### The filter field is a field
24 pt tall, 12 pt text, a 12 pt magnifier, a border that turns accent on focus, and — the fix that
matters most — **the whole capsule takes the click and gives focus**. A `.plain` `TextField` is only
as tall as its text, so clicking the field's own padding used to do nothing. `matches/total` moves to
11 pt monospaced-digit at a readable tint.

### Rows get the leading they were drawing without
`rowHeight` 24 → **26**, `twoLineRowHeight` 36 → **40**, name 12 → **13** (macOS's own source-list
size), subtitle 10 → 11, glyph 11 → 12.5, chevron 9 → 10.5 in a 14 pt column, indent 13 → 14. A
selected row's name goes to `.semibold` and its fill to 0.20, so the selection is legible without
relying on the accent tint alone.

That is about one row per 340 pt of column. ADR-099 took 24 pt from AppKit's source list; the
argument for it was hit area, and the row is a full-width control either way. Legibility is the
better use of the two points.

### The seam answers the pointer
`TreeSplitHandle` paints accent at 2 pt while hovered or dragged. It was a 1 pt separator with an
invisible 11 pt grab area — findable only by discovering it.

### The Diff panel's scope bar is a `PaneHeader`
It was a hand-rolled `HStack` with its own padding, which made three bars of two heights stacked down
one 380 pt panel. Same argument as ADR-102's: two headers of different heights side by side is the
thing that reads as unfinished, and three stacked is worse.

### Quick Open moves to the end of the trailing group
Same rule the tree toggle already follows (ADR-102): a verb that is always present belongs where it
never moves. It was first in the trailing group, so it shifted left every time a file opened and
Revert/Save/pop-out/Reveal appeared beside it.

## Consequences
- `PaneMetrics` gains `control`, `fieldHeight`, `glyph`, `label`; `FileTreeMetrics` gains `nameSize`,
  `subtitleSize`, `glyphSize`. Sizes are named in one place, so the next pass is a number, not a sweep.
- Nothing in `ClinicCore` moves; this is entirely the app target's presentation.
- Verified twice. First by building the **real** `PaneChrome.swift`, `FileTreeRowView.swift` and the
  diff accessories at `HEAD` and at this change into two throwaway apps and screenshotting them side
  by side — the before/after of one pane, same rows, same data (the technique from ADR-096). Then in
  the app, against this worktree: the Files panel on `PaneChrome.swift`, and the Diff panel on the
  working tree, where the scope bar and the browser's two headers finally read as one band.
- Not doing: a user-facing density preference. One legible default first; a preference is a decision
  about *two* defaults and neither has been asked for.
