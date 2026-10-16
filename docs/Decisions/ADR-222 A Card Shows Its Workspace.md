---
status: accepted (built 2026-10-16)
date: 2026-10-16
amends: "[[ADR-156 Sessions Can Be Cards]] (a line for the workspace), [[ADR-212 A Session Is A Workspace Of Tabs]] (step 4, built)"
tags: [adr, ui, sidebar, cards, tabs]
---
# ADR-222: A card shows its workspace

## Context
Step 4 of [[ADR-212 A Session Is A Workspace Of Tabs]]: an open session's card gains a row of glyphs, one per
tab (the main area's, a divider, then the right panel's while it shows), and a ✕ on hover. Compact rows stay one
line. The user accepted this in Grill round 2. The hover ✕ already existed ([[ADR-050 Project Decoration and Actions]]'s
row actions), labelled *Close Tab*.

## Decision
- **`WorkspaceGlyphs`** under a card's meta line, for a session or replay with a tab: a glyph per tab beside
  Claude, a divider, then the right panel's tabs while it shows. Each is the glyph its chip draws (`PaneGlyph`):
  a PR's service mark with its state, a run's status, else the view's symbol. The tab in front of each area is
  secondary and the others tertiary. Clicking a glyph goes to that session and that tab, and its tooltip names
  the tab and says *right panel* where it is in the panel.
- **Nothing is drawn while Claude is alone**, so a card does not gain an empty line.
- **The hover ✕ reads *Close Session*** (*Close Replay* for a replay). It still goes through `TabStore.close` and
  the close sheet.

## Consequences
- Compact rows are unchanged, as the user chose.
- Verified in Clinic Dev: a session with a terminal and Files beside Claude and Diff in the panel showed terminal,
  files, a divider, then diff on its card.
