---
status: accepted (built 2026-09-12)
date: 2026-09-12
amends: "[[ADR-132 The Grill Pane Is A Wizard]] (what a round you cannot answer looks like)"
tags: [adr, ui, panel, grill, keyboard, milestone-4]
---
# ADR-133: History is a list, and a sample round

## Context
User (2026-09-12), on the wizard the same day it shipped: *"For historical rounds, how do you navigate
through the questions? For history should we stick to this wizard style? It would probably make more
sense to display historical rounds as a list. Also it would be nice if I had an easy way to create a
mock round of questions for testing."*

The first question has an embarrassing answer: **you cannot navigate a historical round at all.**
[[ADR-132 The Grill Pane Is A Wizard]] said a round you cannot answer is shown read-only, and the
implementation did that by disabling the wizard — `ProgressStrip` got `.disabled(!actionable)`, the key
handler got `guard isActionable else { return .ignored }`, and the footer dropped Back and Next. Every
one of those is right for *answering*. Together they mean a sent or superseded round shows question 1
and nothing else, with no way to reach question 2. Six questions were stored, one was reachable.

That is not a bug in the wizard so much as evidence that the wizard is the wrong shape here. Every
argument for one-question-at-a-time is an argument about **answering**: a complete answer advances, the
recommendation is the loudest thing on screen, the keyboard is for deciding. A round you cannot answer
has none of that left, and what remains — "what did I decide about the transport?" — is a *reading*
task, which wants everything visible at once.

## Decision

### A round you cannot answer is a list
Sent, superseded, answered-in-the-terminal and replayed rounds drop the wizard entirely: no progress
strip, no Back/Next, no review step. Instead, **every question is a row**, in the order it was asked,
carrying its id, its title and the answer that was given — in `GrillAnswerComposer.answerPhrase`'s own
words, so the list says what the agent read.

A row **expands in place** to show the body, the recommendation and the choices with the picked ones
marked. Expanding rather than a second screen is the point: history is scanned far more often than it
is read, and a list that makes you leave it to see one body is the wizard again with extra steps.

The keyboard follows the list rather than the wizard: `j`/`k` move the focused row, `⏎` or `Space`
expands and collapses it, `⎋` leaves a replay. The `guard isActionable` that silently swallowed every
key becomes a branch, because a round you cannot answer still has a keyboard — it just has a different
one.

This makes the review step and the history list near-twins, which they should be: both list every
question with its answer, and they differ only in what a row *does* — review jumps back to change an
answer, history opens the question to read it. They share the row.

### A sample round, because the pane cannot otherwise be seen
`ask_round` is the only way a round has ever existed, so a reader who has never been grilled sees an
empty state describing a pane they cannot look at, and anyone changing the pane needs a real agent or a
hand-written socket call to test it. Both are fixed by the same thing: **Panel ▸ Post a Sample Round**,
and a button on the pane's empty state offering the same.

The sample is a real round through the real path — `GrillRound.sample()` in `ClinicCore`, posted through
`SessionStore.postGrillRound` like any other — so it exercises what it demonstrates rather than a
parallel code path that can rot. It deliberately contains one of each shape the pane can draw: a
recommendation-only question, a single-select with a recommended choice, a multi-select, a question with
neither (free text only), and a body long enough to be worth reading. Its topic is *Sample round*, so
nobody mistakes it for the agent's.

It is **fully live, Send included**. A sample that could not be sent would not test the one path most
worth testing, and the reader chooses whether to press it.

### Discard, because a sample must be able to go away
A round only ever closed by being sent or superseded. That was survivable while the agent was the only
thing that could post one; it is not survivable now, because an unanswered sample sits in the home
screen's *what needs you* forever ([[ADR-132 The Grill Pane Is A Wizard]]), nagging about questions
nobody asked.

So an open round gains **Discard** — in the footer beside Accept all, and in the rounds menu. It
**removes** the round rather than giving it a fifth outcome. "Discarded" is a word that means gone, a
record of a round the reader explicitly threw away is clutter of a different kind, and the questions are
still in the terminal and the transcript if they are wanted. This is the one place the pane does destroy
something, so it is a deliberate action with a plain name and no keyboard shortcut.

## Consequences
- `GrillPaneModel` gains the history list's focused row and its expanded set; the wizard's `step` stops
  being consulted for a round that cannot be answered.
- Four ways a round can be on screen — answering, reviewing, reading history, and the one-question case
  — but only two layouts, because history and review share their rows.
- `Space` gets a meaning again. [[ADR-132 The Grill Pane Is A Wizard]] deliberately left it unbound when
  the body fold went away; in the history list it is the expander, which is what it was before and what
  it means in Finder. It stays unbound while answering.
- Discard is the first thing in the Grill pane that destroys state. Everything else — supersede, send,
  replay — preserves.
- The sample makes the pane demonstrable without an agent, which is also what makes it testable: the
  smoke key `-ClinicPostGrillRoundOnLaunch` stays for scripted runs, but a human no longer needs it.

## Verification
Driven in an isolated smoke instance (its own `CLINIC_APP_SUPPORT`). **Screen Recording permission for
Claude Code had been declined** — `screencapture` returned "could not create image from display" and the
log named it: *"The user declined TCCs for application, window, display capture"* — so this was verified
through the **accessibility tree** instead of screenshots: a small tool that reads the window's labels
and presses named controls. That is deterministic rather than blind, and it turned out to answer the
questions that mattered, because ADR-133 is about *which questions are reachable*, not about how they
look.

- **The wizard, from the tree**: pips `1 2 3 4` plus the review pip, `Accept` / `Skip` on the question,
  and a footer of `Back | Next | Accept all | Discard` with no Send — Send is review-only, as ADR-132
  says.
- **Sample round**: pressing **Panel ▸ Post a Sample Round** put a round in the state file with all four
  shapes intact — recommendation-only, single-select with three choices, multi-select, and freeform —
  through the same `postGrillRound` the tool uses.
- **Discard** removed the round and left *no* empty entry behind, and the pane fell back to its empty
  state, whose **Post a Sample Round** button posted another.
- **The wizard walked**: Accept all → the first unanswered question, Skip → Skip → the review step
  showing *"What will be sent"* and **Send 4 answers**; pressing it recorded four answers and marked the
  round sent.
- **The fix itself**: with the round sent, **all four question titles were on screen at once** — before
  this change exactly one was reachable. Pressing a row revealed that question's body and no other's;
  pressing it again collapsed it.
- **The history keyboard**, observed by which row opens: `j` then `⏎` opened **Q2**; `j j` then `⏎`
  opened **Q4**; `k k k` then **Space** opened **Q1**. Movement, clamping and both expanders.

455 ClinicCore tests pass (five new for the sample and discard) and `make build` is clean. Smoke
instance and its App Support removed; `com.r0adkll.clinic` gained no keys.

**Still unverified: appearance only** — colours, spacing, the chevron, the focus ring. Those need pixels
and the permission back.
