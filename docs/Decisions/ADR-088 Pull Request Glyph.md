---
status: superseded
date: 2026-09-09
tags: [adr, ui, github, icons]
superseded-by: ADR-089
---
# ADR-088: The pull request glyph is GitHub's curve, not an arrow

> **Superseded by [[ADR-089 Pull Request Glyph Sizing]]** (2026-09-09). The premise below —
> that the arrow only resolves above ~20 pt — was right about the *glyph* and wrong about the
> *fix*: the sizes were inherited from the surrounding text rather than chosen, and raising
> them two points makes `arrow.trianglehead.pull` read. The curve is out; the arrow is back.

## Context
Clinic drew pull requests with `arrow.triangle.pull` in four places — the panel tab, the footer chip,
the sidebar placeholder, and `PullRequestMark` when there is no attention to report. At the 13 pt
Clinic actually uses, that glyph is a short vertical stroke with a small stub: next to the terminal,
diff and files glyphs it reads as "an arrow", not as "a pull request".

User (2026-09-09): "Can we use a better icon for PRs? I think the iOS glyphs have a nice Pull Request
icon that could be used (or pick one from an existing set of icons we use)."

Probed what this macOS actually has, then rendered the candidates at the sizes Clinic draws them
(chip at 13 pt, plus 18 and 26 pt) on the panel's own background:

- **`arrow.trianglehead.pull`** — SF Symbols 6's redraw of the same symbol, solid arrowhead instead
  of a thin open chevron. Semantically exact and it has matching `.merge`/`.branch` siblings. But the
  redraw only becomes visible above ~20 pt; in the chip it is indistinguishable from the old one.
- **`point.topleft.down.to.point.bottomright.curvepath`** — two commit dots joined by an S-curve.
  This is GitHub's own idiom, and the same shape as `branch` in **CodeEditSymbols**, which Clinic
  already vendors through CodeEditSourceEditor.
- `arrow.branch` — a Y-fork; reads as "branch", not "pull request".

## Decision
- **The PR identity glyph is `point.topleft.down.to.point.bottomright.curvepath`**, bound once as
  `PullRequestMark.symbol` in ClinicCore rather than spelled out at four call sites. Chosen for
  legibility at the one size that matters over literal naming: it is the only candidate that is
  recognisably *not just an arrow* in a 13 pt chip.
- **The rest of the family moves to `arrow.trianglehead.*` anyway.** `arrow.triangle.merge` →
  `arrow.trianglehead.merge` (merged, "no conflicts with base") and `arrow.triangle.branch` →
  `arrow.trianglehead.branch` (conflicts, and the new-session/diff branch affordances). These are
  drawn larger and in prose contexts where the solid arrowhead does read, and it keeps one idiom
  across the app rather than two vintages of the same symbol.
- `arrow.triangle.2.circlepath` in the Marketplace is untouched: that is the refresh idiom, not this
  family.

## Consequences
- The PR chip, panel tab and sidebar placeholder no longer look like a generic arrow, at the cost of
  the glyph being literally a *branch/commit path* rather than a pull request. Accepted: GitHub has
  the same ambiguity in the same shape, and the word "PR" is next to it in every chip.
- The identity glyph now has one definition, so changing it again is a one-line edit and the test
  asserts against the constant rather than a string literal.
- Verified on screen in a smoke instance: panel tab, panel header, footer chip and sidebar row.
