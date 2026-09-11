---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-084 Plugin Marketplace]] (the nav row's metrics and glyphs, also taken by [[ADR-093 MCP Server Configuration]] and [[ADR-095 Automations]])"
tags: [adr, ui, sidebar, navigation]
---
# ADR-111: Nav rows wear accent tiles

## Context
User (2026-09-10): *"Then lets beef up the top nav items in the sidebar"*, straight after
[[ADR-109 The Sidebar Toolbar Is Sized Like The Nav Rows]] brought the toolbar up to the nav rows'
size.

[[ADR-084 Plugin Marketplace]] set the nav row (Marketplace, then MCP Servers and Automations with the
same metrics) to a bare 13 pt glyph in an 18 × 16 box, a `.body` semibold label, and a 24 pt pill.
That row was deliberately *shrunk* from a project header's: it had borrowed the header's chevron and
icon columns to line its label up with project names, which pushed it 26 pt off the edge. The
removal was right, but it left the three destinations as the plainest rows in the sidebar, with
bare glyphs above project headers that each carry a 22 pt tile.

## Options
Rendered in a harness beside the toolbar and a project header, dark appearance, with one row
hovered and one active:
- **As was**: 13 pt glyph, 24 pt row.
- **Bigger glyph**: 16 pt glyph, 14 pt label, 30 pt row. More size, same plainness.
- **Colour tiles**: the project header's 22 pt tile in a colour per destination (orange / blue /
  purple) with a white glyph. Built first and shown in the real app. The user asked instead for the
  grey-tile variant *"but make it the accent color like we did in settings"*, which is the same
  correction [[ADR-108 The Settings Window Is A Source List]] made to System Settings' per-pane
  colours.
- **Tiles in the accent wash**: **chosen.**

## Decision
- **Each nav row leads with a 22 pt tile** (the project header's tile size): an **accent glyph on
  accent at 16 %**, 5 pt continuous corner, glyph **12 pt medium**. That is the Settings source
  list's tile (`SettingsPaneIcon`, ADR-108) at the sidebar's tile size, so Clinic's two source
  lists share one tile.
- **On the active row the tile turns white**: a white glyph on white at 22 %. The row's pill is
  the accent, and an accent tile on it would vanish.
- **Outline glyphs**: `storefront`, `server.rack`, `alarm` (they were `storefront.fill` and
  `alarm.fill`). The wash is what carries the weight now. Outlines match the Settings tiles, and
  they finally make the block uniform: [[ADR-095 Automations]] noted that `server.rack.fill` does not
  exist.
- **Label 14 pt semibold**, 8 pt after the tile. Pill: 6 pt interior, 4 pt vertical padding (a
  **30 pt** row), **8 pt** corner (the list's selection radius, measured for
  [[ADR-110 Sidebar Rows Show Hover]]), 10 pt outer inset, 3 pt between rows.
- Still no disclosure column and no indent: ADR-084's reasoning for dropping them stands.
- Each row's accessibility label is the screen's title, not the glyph's name.

## Consequences
- The nav block grows from about 84 to 99 pt. It comes out of the scrolling project list.
- The destinations are told apart by glyph and label, not colour, as the Settings panes are. A
  fourth destination needs no palette decision.
- Verified in smoke instances in dark and light, with MCP Servers active and Marketplace hovered.
