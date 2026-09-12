---
status: accepted (built 2026-09-12)
date: 2026-09-12
amends: "[[ADR-133 History Is A List, And A Sample Round]] (what a row shows), [[ADR-136 Typing An Answer Is Answering]] (the header's counter)"
tags: [adr, ui, panel, grill, milestone-4]
---
# ADR-137: History reads like a record

## Context
User (2026-09-12): *"Let's do a UI/UX pass on the Round history part of the pane. The current UI leaves
a lot to be desired."* Asked what specifically: **"Too cramped, visually noisy."** — and, in the same
breath, they restored Screen Recording, so this is the first change to the Grill pane made with the
pane actually on screen rather than inferred from its accessibility tree.

Looking at it confirms the complaint and adds one defect nothing else would have found.

**Every row is two lines of grey, and the second is written for the agent.** Rows render
`GrillAnswerComposer.answerPhrase`, so an accepted row's second line reads *"accepted your
recommendation: take the recommendation with ⏎, and move on."* The informative part is the tail; the
head repeats on every accepted row. Four rows of that, 6 pt apart, over a fill of
`primary.opacity(0.03)`, is the "wall of grey text" the user is describing — the rows do not separate
from each other and nothing distinguishes one kind of answer from another.

**A skipped question and an unanswered one are identical.** `answerPhrase` returns *"skipped, you
decide."* for both, because an unanswered question **is** sent as skipped — right for the agent, wrong
for a record. On screen: Q3 (`skipped`) and Q4 (no answer at all) were the same row, and only the
header's *3 of 4* hinted otherwise.

**The header counts a round nobody can answer.** *3 of 4* is the wizard's progress; on a sent round it
is a number about work that is finished, and here it was the only thing contradicting two rows that
claimed to say the same thing.

## Decision

### The kind of answer is a badge, not a prefix
Each row carries the badge the wizard already uses — **Accepted · Chosen · Yours · Skipped · No
answer** — and the second line drops the boilerplate and keeps only what is distinctive: the
recommendation's own words, the chosen labels, or the reader's. `answerPhrase` stays exactly as it is
and stays what the *agent* reads; it is no longer also the UI.

**Skipped and No answer are different badges**, because "I decided you should decide" and "I never got
to this" are different things to have done, and a record that cannot tell them apart is not a record.

### A row with nothing to add is one line
Skipped and unanswered rows have no second line at all — the badge has said everything. Decided rows
keep theirs. The list then has rhythm: what you settled is taller and darker than what you passed on,
so the shape of the round is visible before any of it is read.

### The round says what became of it, and when
A header block above the rows replaces the bare sentence: the outcome and its age (*Sent · 2 hours
ago*), then the round's shape by kind (*1 accepted · 1 chosen · 1 skipped · 1 unanswered*). The wizard's
*n of m* counter goes when the round is no longer answerable — a progress figure for finished work is
noise, and the counts say more.

### Room, and one fill that can be seen
Rows sit 8 pt apart with 10/8 interior padding over `primary.opacity(0.05)`, and the focused row keeps
its accent border. The previous 6 pt / `0.03` made four rows read as one block; the point of a list is
that the eye can find the edges of a row without looking for them.

### Walking the list reads it
The focused row expands as the reader arrows onto it, and collapses as they leave. Reading a round
becomes arrowing down it rather than pressing `⏎` on every question; `⏎` and `Space` still pin a row
open so it stays while the reader moves on.

### The review step changes with it
History and the review step share `GrillAnswerRow` ([[ADR-133 History Is A List, And A Sample Round]]),
and they keep sharing it. They are the same object at two moments — what you are about to send, and
what you did send — and letting them drift apart would mean maintaining two answers to the same
question about how an answer looks.

## Consequences
- `AnswerBadge` grows a case for "no answer" and is used in three places rather than one.
- The pane now says *unanswered* in a view whose data model calls it *skipped* when it sends. The
  composer is unchanged: this is a difference between what the reader is shown and what the agent is
  told, and it is deliberate.
- A row's height now depends on its answer, so the list is no longer uniform. That is the point, but it
  means the history list cannot be a fixed-row `List` if it is ever rebuilt as one.
- The round header is the third place that formats a round's outcome, after the rounds menu and the
  read-only banner. They should be one helper before a fourth appears.

## Verification
**The first change to this pane verified by looking at it.** Screen Recording was restored, so this was
built by screenshot rather than by accessibility tree, and three of the fixes below exist only because
they were visible.

Seen on a sent round carrying all four answer kinds:

- The header block reads **Sent · just now** over *1 accepted · 1 chosen · 1 skipped · 1 unanswered*.
- Rows carry **Accepted / Chosen / Yours / Skipped / No answer**, and the summary line holds only the
  distinctive part — *"take the recommendation with ⏎, and move on"* rather than the agent's phrase.
- **Skipped and No answer are visibly different rows**, which was the defect this ADR exists for.
- Skipped and unanswered rows are a single line; decided rows are two. The list has rhythm.
- Arrowing onto a row expands it; the focused row's detail shows the body and the recommendation.

Three things only the screenshots caught, each fixed after seeing it:

1. `RelativeDateTimeFormatter` renders a just-sent round as **"in 0 seconds"** — both wrong and odd.
   Under a minute now reads *just now*.
2. An expanded row **printed its recommendation twice**: once as the collapsed summary, once in the
   detail. The summary is the collapsed form of the detail, so it goes while the detail is showing.
3. The detail sat against the bottom of the focus ring with no breathing room.

455 ClinicCore tests pass and `make build` is clean. Smoke instance and its App Support removed.

### A note on the driving, not the pane
Two runs recorded every question as unanswered, and a third lost only the typed one. The cause was not
the pane: a **TCC dialog was sitting over the window eating keystrokes**, which a screenshot showed
immediately and the accessibility tree never would have. Synthetic typing into the `NSTextView` stayed
unreliable afterwards even with real key codes, so the *Yours* badge was confirmed from an earlier
capture rather than reproduced on demand. A human types into it correctly — this session's own round
was answered that way.
