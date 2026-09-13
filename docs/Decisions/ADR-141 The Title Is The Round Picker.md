---
status: accepted (built 2026-09-12)
date: 2026-09-12
amends: "[[ADR-137 History Reads Like A Record]] (its header block), [[ADR-133 History Is A List, And A Sample Round]] (how rounds are picked)"
tags: [adr, ui, panel, grill, milestone-4]
---
# ADR-141: The title is the round picker

## Context
User (2026-09-12): *"I don't think we need the 'Sent' banner at the top of round history. Another UX
improvement would be to make the whole round/title a dropdown instead of the history icon when in this
view."*

Two things, and they fit together.

[[ADR-137 History Reads Like A Record]] put a `HistoryHeader` block at the top of a history round: a
glyph, the outcome, its age, and a second line counting answers by kind. It tells the reader something
they mostly already know — *Sent* is what happens to nearly every round — and it does so in the most
prominent position in the view, above the thing they came to read.

Meanwhile the way to *move between* rounds is a clock glyph in the header, sharing a row with the copy
button and looking like one more icon action. It is the primary navigation of this view and it is drawn
as the least prominent control in it.

## Decision

### The `HistoryHeader` block goes
Deleted, not shrunk. Its outcome and counts were not worth the vertical space above the rows, and the
two things it said are better placed: the outcome belongs to the round picker, where it helps choose,
and the counts are of little use once every row shows its own answer ([[ADR-137 History Reads Like A Record]]).

### The title is the picker
The pane's title — *Round 3 · Grill panel design* — becomes the menu, with a chevron, and the clock
glyph is removed. The control that changes which round you are looking at is now the thing that says
which round you are looking at, which is where a reader looks first and the only place that needs no
explaining.

Each item still carries its round's outcome and question count (*Round 2 — superseded · 6*), so
outcome survives exactly where it earns its place: when you are choosing between rounds.

The title is a menu whenever the session has more than one round, in the wizard as well as in history,
rather than only "in this view". One control in one place beats chrome that changes shape with the
mode, and switching away from an open round costs nothing — a replay is read-only, answers are already
persisted, and `⎋` or *Back to the open round* returns.

### "Sent" goes; "not sent" stays
The reader objected to being told *Sent*, and they are right: it is the expected outcome, and a round
you are reading in history is almost always one you sent. But two outcomes are **not** unremarkable:

- **superseded** — the agent moved on and anything the reader entered was never sent;
- **answered in the terminal** — this copy is a record of something that happened elsewhere.

Both are surprises, and a reader who is not told will reasonably assume their answers went. So
`ReadOnlyBanner` — which [[ADR-137 History Reads Like A Record]] orphaned when it introduced the header
block, leaving it in the file unreferenced — comes back for those two, and `readOnlyNote` returns nil
for `sent`. The rule is: **say nothing about the ordinary, say plainly what would surprise.**

## Consequences
- A sent round now opens straight onto its questions, with no chrome above them at all.
- The age of a round is no longer shown anywhere. It was the weakest part of the header block and
  nothing has asked for it; `postedAt` is still on the round if it is ever wanted.
- One control fewer in the header row: the clock is gone and nothing replaced it.
- The title gains a hit target it did not have, so a reader who clicks it expecting nothing now gets a
  menu. With a single round it stays plain text, so the affordance only appears when it does something.

## Verification
Through the accessibility tree (Screen Recording is still declined for Claude Code), on a session with
three rounds — one sent, one superseded, one open.

- **One round**: the title is plain text — the pane contributes no menu button.
- **Two rounds**: the title becomes a menu, labelled with the round it is showing
  (`Questions · Sample round`), and the clock glyph is gone.
- **A sent round** carries no note and no header block: `You sent these answers` and the counts line
  (`… accepted · …`) are both absent, and the questions are the first thing in the view.
- **A superseded round**, reached by picking it from the title menu, still says
  *"The agent moved on to the next round…"* — the surprise that would otherwise leave a reader
  believing answers they typed had been sent.
- Picking rounds from the title menu works for both, so the picker is doing the job the clock did.

455 ClinicCore tests pass and `make build` is clean. Smoke instance and its App Support removed.

**Appearance unverified**, as throughout: the chevron, the menu's hover treatment and the spacing freed
by deleting the header block have not been seen.
