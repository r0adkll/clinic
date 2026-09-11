---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-077 Persistent Projects and Sidebar Polish]] (the toolbar's \"compact\" metrics and its \"no caption\"); [[ADR-062 Project Groups]] (the collapse-all / expand-all glyphs)"
tags: [adr, ui, sidebar, toolbar]
---
# ADR-109: The sidebar toolbar is sized like the nav rows

## Context
User (2026-09-10): *"Lets increase the size of the actions above the projects in the sidebar. Let's do
a UI/UX improvement pass"*

The "actions bar" (the user's own name for it in [[ADR-084 Plugin Marketplace]]) is the icon row
between the pinned nav block and the project list: Select, Collapse All, Expand All, Add Project.
[[ADR-077 Persistent Projects and Sidebar Polish]] made it "right-aligned and compact": 11 pt
glyphs in 22 × 20 boxes, 1 pt apart, 8 pt from the sidebar edge. Next to what surrounds it that was
the smallest thing in the sidebar by a clear margin: the nav rows above it draw 13 pt *filled* glyphs
in a 24 pt pill, the project headers below a 22 pt icon. Four outline glyphs at 11 pt in secondary
grey read as disabled chrome, and a 22 × 20 target was the smallest click in the window.

A screenshot of the live sidebar showed three more problems beyond size:
- **The expand-all glyph was `chevron.down`**: the same glyph as every project header's
  disclosure chevron a few points below it. **Collapse-all was `chevron.up.chevron.down`**: the
  pop-up button / stepper mark, which on macOS means "choose from a list", not "fold".
- **Nothing showed that Select mode was on** except the glyph turning accent-coloured, and only
  one of its two symbols (`checklist.checked`) even hints at that.
- **The buttons did not know when they had nothing to do.** Collapse All with everything collapsed,
  or either fold button while a filter is typed (folding is suspended then, every match shows), looked
  exactly as clickable as when it would do something.

## Options
Rendered in a harness at the real sizes, dark appearance, beside a copy of the nav row and a project
header:
- **11 pt / 22 × 20** (as was): too small, which is the complaint.
- **13 pt / 26 × 24**: bigger, but outline glyphs at 13 pt still read lighter than the nav block's
  filled glyphs at the same size; in the real app it looked like a half-step.
- **14 pt / 28 × 24**: the same visual weight as the nav glyphs above it. **Chosen.**
- **15 pt / 30 × 28**: starts competing with the project icons, and a 36 pt row is taller than a
  nav row for four icons.

For the fold pair: `rectangle.compress.vertical` / `rectangle.expand.vertical` rendered busy at
this size (the compress one reads as "insert a line"). `arrow.down.and.line.horizontal.and.arrow.up`
/ `arrow.up.and.line.horizontal.and.arrow.down` (arrows converging on a line vs. leaving it) read as
the verbs at a glance. Both pairs ship in SF Symbols 3, inside the macOS 15 floor. `chevron.up.2` /
`chevron.down.2` exist on this machine but were not considered: macOS 15 support was not confirmed.

A single state-driven fold toggle was considered and rejected. It saves one button but turns "expand
everything" into two clicks whenever the fold is mixed, and the row has room for four targets at the
new size.

## Decision
- **Metrics.** `ToolbarIcon` draws a 14 pt medium glyph in a **28 × 24** box (the nav pill's
  height when this was decided; [[ADR-111 Nav Rows Wear Accent Tiles]] later grew the pill to 30)
  with a **6 pt** corner, **2 pt** apart. The row's horizontal inset is **10 pt**, the nav pills'
  outer inset, so the Add Project box's trailing edge lines up with the pills and the search field
  above it (it was 8). A 14 pt divider with 4 pt either side before Add Project.
- **Collapse All is `arrow.down.and.line.horizontal.and.arrow.up`, Expand All is
  `arrow.up.and.line.horizontal.and.arrow.down`.** Their help reads "Collapse all projects" /
  "Expand all projects".
- **A latched mode is a filled button.** While Select mode is on the button draws its accent glyph
  on an **accent wash** (18 %, 26 % under the pointer), not the glyph alone.
- **A button with nothing to do is disabled**, drawn tertiary with no hover fill: Collapse All
  when no project is expanded, Expand All when none is collapsed, and both while the filter field
  has text.
- **Each button carries its help text as its accessibility label**, instead of VoiceOver reading
  out the symbol name ("checklist", "folder badge plus").
- **The row is captioned "Projects"**, reversing ADR-077's "no caption". `.subheadline` semibold,
  secondary, starting 6 pt inside the row's inset, which is where the nav rows' tiles start. It was
  put in as a trial (*"just to see"*) with a known cost: when favourites exist, the first section
  under it is **Favorites**, in nearly the same style, which reads as a sub-section of Projects. The
  user saw that in a screenshot and kept it (*"I also like the "Projects" title so we can keep
  that"*). ADR-077's objection was to "Sessions", which misnamed the list. "Projects" names what
  the row's buttons act on, and it makes the row read as the list's header, not a fourth nav row.
- **12 pt above the row, 4 pt below** (it was 4 and 4). The extra 8 pt separates the nav block from
  the list this row heads, per the user's *"a bit more padding between the nav items and the
  projects bar/list"*.
- Unchanged from ADR-077: the buttons right-aligned, the divider and the 8 pt gap below it outside
  the scroll view.

## Consequences
- The row grows from 28 to 40 pt (32 from the buttons, 8 more from the gap above). That space comes out of
  the scrolling list, not the nav block.
- `ToolbarIcon` is used only by this row, so nothing else in the app changes size.
- `SidebarView` computes the two fold availabilities on every body pass, which walks
  `sessions.projects` twice. That list is a handful of entries.
