---
status: accepted (built 2026-10-15)
date: 2026-10-15
amends: "[[ADR-077 Persistent Projects and Sidebar Polish]] (the header's 12 pt chevron column and its 6 pt gap are gone)"
tags: [adr, ui, sidebar, projects]
---
# ADR-209: The project icon is its fold control

## Context
User (2026-10-15): *"Let's do a UX/UI improvement pass on the project sidebar. One idea I've been thinking about
is rolling the collapse/expand carot into the project icon. So when you hover over the icon it gets scrim'd and
the carot becomes visible and clicking toggles the collapse expand."*

[[ADR-077 Persistent Projects and Sidebar Polish]] gave every project header a 12 pt chevron and a 6 pt gap
before its 22 pt icon. That is 18 pt of every header spent on a control used now and then, in a sidebar narrow
enough that ADR-077 rejected a 6 pt outline indent for costing title width. It also put the project tiles in a
different column from the nav rows' tiles and the *Projects* caption above them, which the nav rows' own
comment had to explain away ("no phantom disclosure column").

## Decision
- **The chevron moves onto the icon.** `ProjectFoldIcon` wraps `ProjectIcon` in a button. At rest it is just the
  icon. With the pointer on the tile, a black scrim covers it (0.55, 0.7 while pressed) with a white bold
  `chevron.right` on top, pointing right when collapsed and down when expanded. Clicking it collapses or expands
  the project, as the chevron did. Only the tile reacts; the rest of the header still starts a session.
- **The tile is blurred under the scrim** (2 pt, opaque, clipped to the tile's corner). A first pass used a plain
  0.45 scrim. The icon's own glyph still showed through it, so `clinic`'s `>+` read as `>>` and a monogram
  fought the chevron. The blur leaves the tile's colour, which is enough to tell projects apart while hovering.
- **The scrim and chevron fade in over 0.12 s**, and the chevron turns over 0.2 s when the state changes.
- **The header moves 2 pt right.** Without the chevron column the tile landed 2 pt left of the nav rows' tiles
  and the *Projects* caption. With the nudge all three share one leading edge, measured in a screenshot.
  The name gains 16 pt of width.
- **Help and accessibility say what a click does:** "Expand ‹project›" or "Collapse ‹project›". The list
  combines a section header into one heading, so VoiceOver reaches the control as a named action on the
  project's heading, the same way it reached the chevron.
- The collapsed state no longer shows at rest. A collapsed project is still told by the rows missing under it,
  and the count pill still says how many there are.

## Consequences
- Session rows are unchanged. Their glyph column used to sit under the chevron. It now sits under the left
  half of the project tile, which reads as nested without an indent.
- Collapse All and Expand All in the toolbar are unchanged.

**Verified** in Clinic Dev. At rest, the headers have no chevron and the tiles line up with the nav tiles. With
the hover state seeded by a temporary launch argument (removed before committing), every tile showed the
scrim. The blurred version reads `>` on the collapsed `clinic` and `⌄` on the expanded projects. The fold
action pressed through the accessibility API expanded `clinic` and flipped its action to "Collapse clinic".
Pressing it again collapsed it. A real pointer hover was not seen, because the Dev window was behind the
user's windows and taking focus was not worth it; hover it once by hand.
