---
status: accepted
date: 2026-09-09
supersedes: ADR-088
tags: [adr, ui, github, icons]
---
# ADR-089: Size the pull request glyph deliberately, then the arrow reads

## Context
[[ADR-088 Pull Request Glyph]] compared `arrow.trianglehead.pull` against GitHub's two-dot curve at
the sizes Clinic drew them, found the arrow indistinguishable from any other small arrow, and picked
the curve. That comparison was sound but it took the *sizes* as fixed, and they were never chosen in
the first place: every PR glyph inherited the point size of whatever text it sat next to — `.callout`
(12 pt) in the footer chip, `.caption` (10 pt) in the sidebar and the panel tab strip, `.body` (13 pt)
in the panel header. The glyph was small because nobody had decided how big it should be.

User (2026-09-09): "Lets try the arrow.trianglehead.pull, but lets make the icons larger so they
appear visually correct."

That reframes it. `arrow.trianglehead.pull` is a tall, narrow shape — a vertical stroke, a stub, and
a solid head — so at the same nominal point size as the boxy glyphs beside it (`terminal`,
`doc.text.magnifyingglass`) it occupies far less ink and reads smaller. It needs optical
compensation, which is a normal thing to owe a glyph, not a reason to reject it.

## Decision
- **Back to `arrow.trianglehead.pull`** as `PullRequestMark.symbol`. It is the symbol that actually
  means "pull request", and the whole family (`.merge` for merged and "no conflicts", `.branch` for
  conflicts and the branch affordances) is one idiom again.
- **Every site sizes the glyph explicitly**, ~2 pt over the text it accompanies, collected in one
  table as `PRStyle.glyphSize` so the relationship is visible and adjustable in one place:
  chip 14, sidebar 12, header 15, status line 13, tab strip 12.
- **The panel tab strip compensates per kind.** `PanelPane.Kind.glyphSize` returns 10 pt for the boxy
  glyphs and `PRStyle.glyphSize.tab` for `.pr`, so the strip stays optically even instead of
  nominally even.

## Consequences
- The status-line glyph frame widens from 14 to 16 pt to fit the larger symbol without shifting the
  text column.
- `PullRequestMark.symbol` is still bound once (the one thing ADR-088 got right that survives), so
  this was a one-line change plus the sizing table.
- The general lesson, worth more than the glyph: when an icon looks wrong, check whether its size was
  *chosen* before concluding the icon is wrong. Inheriting a text style is a default, not a decision.
- Verified on screen in a smoke instance at all four sites: panel tab, panel header, footer chip
  beside the Files toggle, and the sidebar row.
