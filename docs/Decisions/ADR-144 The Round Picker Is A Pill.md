---
status: accepted (built 2026-09-12)
date: 2026-09-12
amends: "[[ADR-143 The Round Picker Says Which Round]] (how its label is drawn)"
tags: [adr, ui, panel, grill, milestone-4]
---
# ADR-144: The round picker is a pill

## Context
User (2026-09-12): *"Could we add a little more decoration (like a box/pill) around the round title and
chevron drop down. I also feel like we could use a smaller dropdown glyph and it could be located to the
right of the text."*

The third note is the interesting one, because the chevron **is** already right of the text — and
reading the label explains why it does not look it:

```swift
.padding(.horizontal, 5)
.padding(.vertical, 3)
.frame(maxWidth: 220, alignment: .leading)
.background(hovering ? … : .clear, in: RoundedRectangle(…))
```

The 220 pt cap is on the **padded stack**, not on the text, and `.background` is applied *after* it. A
`.frame(maxWidth:)` makes a view flexible up to that width, and the header offers plenty — a `Spacer`
follows — so the container is 220 pt wide whatever the title says. The content sits at its leading edge
and the fill covers the whole slab. So on hover the reader gets a wide rectangle with the title and
chevron huddled in its left end, and the chevron reads as adrift rather than attached.

[[ADR-143 The Round Picker Says Which Round]] intended the cap to *truncate a long title*. Put on the
wrong view, it stretched a short one instead.

## Decision

### The cap belongs to the text — and has to be the text, not a frame
The title is **shortened with an ellipsis** until it fits 220 pt, measured in the label's own font. A
short round name keeps its own width and the stack hugs it; a long one stops at the cap. The pill is
then whatever the content is, and the chevron sits against the title at every length.

It is the *string* that is bounded, and not for tidiness. Nothing applied to the **view** held:

| Attempt | Measured width of a long title |
|---|---|
| `.frame(maxWidth: 220)` on the padded stack | 220 pt **whatever the title said** — the original bug |
| `.frame(maxWidth: 220)` on the `Text` | 449 pt |
| `.frame(width:)` on the `Text`, measured | 449 pt |
| …plus `.fixedSize()` on the `Menu` | 606 pt |
| Truncating the string | **237 pt**, and 105 pt for a short one |

`maxWidth` clamps only against a *proposed* width, and a `Menu` sizes its label by the label's **ideal**,
so an unspecified proposal passes the ideal straight through — and a fixed frame underneath is not
honoured either. There is no dependable way to argue with a `Menu` about its label's size from inside
it, so the ideal is made small instead. This is the same shape of finding as
[[ADR-107 The Images Pane Has A Finder Keyboard]]'s about `.onKeyPress`: the framework has a path it
will not be talked out of, and the way through is to stop asking.

### The pill is always there
A capsule behind the label at rest — not only on hover. This control is the pane's primary navigation
([[ADR-141 The Title Is The Round Picker]]) and it was drawn as bare text; a reader had to discover it
by pointing at it. Hover still lifts the fill, so the affordance has two steps rather than one:
*something is here*, then *and it is under your pointer*.

A capsule rather than the rounded rectangle `PaneIconButton` uses: the icon buttons are square targets
in a row, and a pill reads as a distinct kind of thing — a value you can change — which is what this is.

### A smaller chevron
7 pt, down from 8, and `.bold` so it holds at that size. The glyph is a hint that the title opens
something, not a control in its own right; at 8 pt beside 12 pt text it was competing with the words.

## Consequences
- The picker's width now tracks its title, so the header's hint and counter get the space a short round
  name leaves behind — space the 220 pt slab was taking whatever the title said.
- One more always-drawn surface in a header that was deliberately quiet. It earns it by being the only
  control there that changes what the pane is showing rather than acting on it.
- `PaneMetrics.radius` is no longer used by this label; the capsule has no corner radius to share.
- The title in the header can now differ from the round's full name by an ellipsis. The picker's items
  are not truncated, so the full name is always one click away.

## Corrections
`.fixedSize()` was blamed for the slab and removed. It was not the cause: on its own it hugs, and it
only produced 220 pt because the label beneath it carried `.frame(maxWidth: 220)`, so the "ideal" it
hugged *was* 220 whatever the title said. It is back, and correct, now that the label's ideal is bounded
by its text.

Three of the four fixes above were wrong, and each was written down as if it would work before being
measured. The measurement took seconds and the reasoning took longer — a standing argument for putting
a number on a layout claim before committing to it.

## Verification
Through the accessibility tree, reading the picker's own frame (Screen Recording is still declined for
Claude Code).

- **Short title**: 105 pt, label `Sample round` — the pill hugs the name. It was 220 pt regardless before.
- **Long title**: 237 pt, label `Round 9 · A deliberately very long r…` — truncated at the cap rather
  than widening the header.

456 ClinicCore tests pass and `make build` is clean. Smoke instance and its App Support removed.

**Unverified, and it is most of what was asked for**: the capsule itself, its resting and hover fills,
and the 7 pt chevron are pixels. The geometry is now measured; the look is not.
