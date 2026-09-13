---
status: accepted (built 2026-09-12)
date: 2026-09-12
amends: "[[ADR-141 The Title Is The Round Picker]] (what the picker shows and what picking does)"
tags: [adr, ui, panel, grill, milestone-4]
---
# ADR-143: The round picker says which round

## Context
User (2026-09-12): *"The round dropdown in the topbar on the grill panel could use some polish."*

Reading it back found one thing that is not polish.

**Picking an older open round takes you somewhere else.** The item's action is
`model.viewingRoundId = round.isOpen ? nil : round.id` — written under
[[ADR-141 The Title Is The Round Picker]], when exactly one round could be open, so "open" and "the one
the view falls back to" were the same thing. [[ADR-142 Only The Reader Closes A Round]] made several
rounds open at once and did not revisit this line. With two open rounds, picking the older sets
`viewingRoundId` to nil, the view falls through to *newest open*, and the reader lands on the round they
did not choose.

That is the third time in this feature that a later decision has quietly invalidated an earlier one's
assumption. It is worth naming as a habit rather than an accident: **when an ADR removes a constraint,
the code that was written under it is now unjustified and has to be re-read**, not just left compiling.

The rest is genuinely polish, and all of it follows from the picker having been designed when rounds
were few and singular:

- Every unnumbered round reads **"Questions"**, so several are indistinguishable — which is exactly the
  sample round's case, and any round the agent did not number.
- An open round says **"waiting · 4"** and not how much of it is done, which is the thing you would
  choose on now that more than one can be waiting.
- **Nothing marks the round you are on.** A macOS menu marks its current item; this one does not.
- Open rounds and finished ones sit in **one flat list**.
- The label has `.lineLimit(1)` and `.truncationMode(.tail)` and then **`.fixedSize()`**, which defeats
  both: a long topic widens the header instead of truncating, squeezing the mode hint and the counter at
  the pane's 460 pt minimum.
- The label has **no hover treatment**, unlike every other control in this chrome
  ([[ADR-103 File Browser Chrome Is Sized To Be Hit]]).

## Decision

### Picking a round shows that round
`model.viewingRoundId = round.id`, always. No branch, no cleverness about which round is "the fallback".
Leaving a chosen round stays what it was: `⎋`, or *Back to the open round*, both of which clear it
explicitly.

### An item says which round, how far through, and where you are
Each item carries, in order: a checkmark column marking the round on screen; the outcome's glyph; the
round's name; and its state.

- **Name** prefers `Round 3 · topic`, falls back to the topic alone when the agent did not number it,
  and only reaches *Questions* when it has neither. The header's title and the menu now derive their
  name from one function, so they cannot disagree.
- **State** for an open round is its progress — *not started*, *3 of 6 answered*, *ready to send* — and
  for a finished one the outcome word it already had.

### Open rounds come first, separated
Rounds still waiting are listed newest-first above a divider; everything else below it. With several
rounds open at once the reader's work and their history are two different lists, and a divider is the
cheapest way to say so.

### The label truncates and responds to the pointer
`.fixedSize()` goes; the title is capped at **220 pt** — the width a tab chip caps at
([[ADR-079 Panel Tabs]]) — and truncates past it. The whole label sits in a rounded rectangle that
fills on hover, the same treatment `PaneIconButton` gives every other control in this header.

## Consequences
- `name(for:)` is shared by the header title and the menu items; a round is called the same thing
  everywhere it appears.
- The picker grows a checkmark column, so its items are wider. That is the cost of a menu that says
  where you are, and menus are allowed to be wider than the pane.
- Open rounds and history being separated makes the menu the place the reader sees how many rounds are
  waiting, which the pane's chip already counts.
- Nothing here changes the keyboard: the picker remains a pointer control, as
  [[ADR-141 The Title Is The Round Picker]] left it.

## Verification
Through the accessibility tree, on a session with three rounds. Menu items were read and pressed by
name, so what is checked below is what the menu actually contains.

- **The bug**: with three open rounds, picking the *not started* one moved there (no `Accepted` badge),
  and then picking *1 of 4 answered* landed on **that** round — the badge came back. Before this, picking
  any open round cleared `viewingRoundId` and the view fell through to the newest.
- **Items carry progress**: `Sample round — not started`, `Sample round — not started`,
  `Sample round — 1 of 4 answered`, newest first.
- **The name falls back to the topic**: three unnumbered rounds read *Sample round* rather than three
  identical *Questions*, and the header agrees, both now coming from `name(_:)`.
- **Waiting above history**: after sending one round, the sent one is listed last, below the two still
  waiting.

456 ClinicCore tests pass and `make build` is clean. Smoke instance and its App Support removed.

**Not verified, and it is the half the request was about**: the checkmark column, the hover fill and the
220 pt truncation are pixels, and Screen Recording is still declined for Claude Code. The structure is
right; how it looks is still taken on faith.
