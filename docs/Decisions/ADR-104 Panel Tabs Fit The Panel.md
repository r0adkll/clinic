---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-079 Panel Tabs]] (strip metrics only)"
tags: [adr, ui, panel]
---
# ADR-104: Panel tabs fit the panel

## Context
User (2026-09-10), after [[ADR-103 File Browser Chrome Is Sized To Be Hit]]: *"Can we also take a
pass at improving the tabs/tab bar for the right panel?"*

[[ADR-079 Panel Tabs]] built the strip out of `TabChip`'s metrics on purpose — "both strips read as
the same control". But the session tab bar spans the window and the panel strip spans a **380–520 pt
column**, and one set of metrics cannot serve both:

- **Three labelled chips need about 320 pt.** A fourth — a PR, or Images — did not fit, and the strip
  is a `ScrollView(showsIndicators: false)`, so it scrolled the tab out of sight with nothing on
  screen saying it had. ⌘⌃] could then select a tab the reader could not see.
- **An unselected chip had no fill at all.** Only the selected one was a chip; "Terminal" and "Files"
  sat there as bare glyph-and-label pairs. The strip did not read as a row of tabs, and a chip
  admitted it was a control only once the pointer was on it.
- **The `+` was a bare `Image` in a borderless menu** — the same fault ADR-103 found in the file
  browser headers: it hit-tests as the glyph, and at the trailing edge of a dim bar it was easy to
  miss. Worse, `availablePanes` empties once every kind is open, so the control **disabled itself**
  and sat there greyed out, explaining nothing.
- The close ✕ was 10 pt with the glyph as its hit area.

## Decision

### The strip adapts to its width
`ViewThatFits` over three candidates, in order:

1. **labelled chips** — glyph, title, close ✕;
2. **compact chips** — glyph only, 24 pt tall and ~28 pt wide;
3. **compact chips in a `ScrollView`** — the backstop.

`ViewThatFits` falls through to its *last* candidate when none fit, which is what makes scrolling the
last resort rather than the default. Six compact chips fit a 320 pt panel, so in practice the third
candidate is unreachable without a great many open pull requests.

**A chip's `maxWidth` is a cap on a long title, not a width to grow into.** The row is
`.fixedSize(horizontal: true, vertical: false)`; without it the strip hands the row its whole width,
every chip stretches to its 200 pt cap, and three tabs that *measure* 340 pt to `ViewThatFits`
*draw* 600 and overflow the panel. That bug is invisible in the session tab bar, where the enclosing
`ScrollView` proposes unbounded width and the chips fall back to their ideal size.

### Every chip is a chip
A resting fill (`primary` at 0.05) on every tab, hover at 0.11, selected at accent 0.20 with an accent
border and accent contents. In the compact form this is not decoration: a glyph with no chip around it
is a toolbar icon, and the strip stops reading as tabs at all.

### The `+` is a control, and it never disables
`PaneIconMenu` — ADR-103's `PaneIconButton` shape with a menu behind it, so a menu and a button in the
same band are the same 24 × 24 target and highlight the same way.

Its menu lists **the open panes as well as the addable kinds**, in two sections. That makes it the
strip's overflow list: in the compact form the chips are glyphs, and this is where their names are.
It is therefore never empty and never disabled.

### The selected tab is scrolled into view
Only reachable in the scrolling candidate, but ⌘⌃] / ⌘⌃[ and the footer quick actions all change the
selection from outside the strip, and the tab they chose could be off the end of it.

### Glyph sizes come in two
`Kind.glyphSize(compact:)`: 11 pt labelled, 13 pt compact, and the PR glyph ~2 pt over the boxy ones
either way — [[ADR-089 Pull Request Glyph Sizing]]'s rule, now expressed as a relationship rather than
one constant. `PRStyle.glyphSize` gains `tabCompact`.

### What stays
The chip's *shape* — 6 pt corners, accent selection, close on hover-or-selected, the Close / Close
Others menu — is still `TabChip`'s, so ADR-079's "both strips read as the same control" holds for the
labelled form. The panel's show/hide still lives in the session tab bar and is not repeated here.

## Consequences
- A compact chip has **no close button**: where there is no room for a name there is no room for a
  verb. Closing is the context menu, ⌘⌃W, or the `+` menu's list. Putting an ✕ *over* the glyph on
  hover (Safari's pinned tabs) was rejected: it puts a destructive target under a pointer that came
  to select.
- Not doing: drag to reorder, and middle-click to close (SwiftUI has no middle-click gesture; it
  wants an `NSView` representable, which is a bigger change than this pass).
- The panel is not the only narrow tab strip Clinic might grow. `ViewThatFits` over a compact form is
  the pattern to copy, not the numbers.
- Verified in a harness that renders the **real** strip source at 320 / 380 / 430 / 560 / 760 pt with
  3, 4 and 6 tabs, and then in the app at a 430 pt panel and at the 380 pt floor.
