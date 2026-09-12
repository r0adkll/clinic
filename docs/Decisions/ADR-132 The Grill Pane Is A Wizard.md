---
status: accepted (built 2026-09-12)
date: 2026-09-12
supersedes: "[[ADR-131 The Grill Pane Answers A Round]] (the pane's shape only — its transport, tool, schema, supersede rule and corrections all stand)"
tags: [adr, ui, panel, grill, keyboard, milestone-4]
---
# ADR-132: The Grill pane is a wizard

## Context
[[ADR-131 The Grill Pane Answers A Round]] shipped the same day this was written, and its pane was a
**scroll of question cards**: the whole round on one surface, each question a card with its body folded
past 220 characters, answered in any order, sent from a footer that was always there.

Then it was used. A real grill about the pane's own remaining decisions ran four rounds and 23
questions through it — the first time anyone answered a round rather than a fixture — and the reader
asked for one question at a time instead. That one answer retires most of ADR-131's presentation: the
flat row list, the body fold, the whole-round scroll and the always-present Send all existed to make
six cards coexist on one surface, and nothing has to coexist any more.

Everything *underneath* the presentation came through the same grill unscathed and is not reopened
here: `ask_round` posts and returns, the answers arrive as the reader's next message, the schema, the
supersede rule, persistence, `⌘⇧K`, `⌘⌃C`, and ADR-131's three corrections. **This ADR replaces how a
round is shown and answered, and nothing else.**

## Decision

### One question at a time
The pane shows a single question. `j`/`k` (and `↑`/`↓`) step between them and **do not wrap** — a wizard
has a beginning and an end, and wrapping makes "have I reached the end?" unanswerable by feel. Bodies
are shown in full: the 220-character fold existed so six cards would fit, and `Space`, which used to
open a fold, goes back to being unbound rather than being given an invented new meaning. `minWidth`
stays 460, because a choice with a detail line still needs the width.

### A complete answer advances; an incomplete one does not
Accepting with `⏎`, skipping with `s`, and picking in a **single-select** question all move to the next
question. A **multi-select** pick does not — the reader is not finished, and advancing on the first
checkbox would be wrong. That is the whole rule, and it is why a six-question round you agree with is
six keystrokes.

The free-text field stays visible under the choices rather than hiding behind `e`: with one question
owning the pane there is room, and a field you can see is the discoverable way to say something the
choices do not cover. `e` focuses it, `⎋` leaves it with the draft intact, `⇥` commits and advances —
consistent with the rule, since a committed answer is a complete one.

### A progress strip and a review step
A wizard hides five of six questions, so it owes the reader two different things, and they are not the
same thing:

- **Orientation** — a header strip of numbered pips carrying *state*: filled = answered, hollow = not,
  an accent ring on the current one, and a final pip for the review step. Click to jump; there is no
  key, because `1`–`9` already picks a choice. Position alone ("3 of 6") would say where you are but
  not how much is left.
- **A last look** — a **review step** past the last question, listing every question with the answer
  it will send. Every row jumps back to its question, by click or `⏎` on the focused row: a review you
  cannot act on is a receipt, not a review. `j` from the last question lands here and `k` goes back.

**Send lives on the review step**, so the wizard has an end you arrive at — but `⌘⏎` still sends from
anywhere, because someone who knows they are done should not have to walk there. While in questions the
footer carries Back / Next and *Accept all recommendations*.

**Accept all** fills every unanswered recommendation and then jumps to the first question that still has
no answer — the ones that actually need thought — falling through to the review step when there are
none. Filling in place was fine when the reader could see the result; in a wizard the button has to
decide where to leave them, and "do the easy ones, then put me where the work is" is what it is for.

### One question is not a wizard
A round with a single question shows neither strip nor review: just the question, with Send in the
footer. A one-pip progress strip above a review listing one answer is ceremony around nothing — the
same instinct as [[ADR-126 An Unconfigured Run Pill Opens The Editor]], which opens the editor rather
than a chooser with nothing to choose. Both appear at two questions or more.

### The pane is never empty while it has a history
With nothing open — the round sent, or superseded — the pane shows **the last round, read-only**, beside
a **rounds menu** in the header that replays any earlier one. Replacing the round with "nothing here"
the instant Send is pressed would erase what the reader was just working on. The empty state survives
only for a session that has never had a round. `⎋` leaves a replay, and its footer offers only *Back to
the open round*, there being nothing to send.

### A superseded round keeps everything
The supersede rule means the agent can post round 5 while the reader is halfway through round 4, with
committed answers in the state file and a half-written paragraph in a draft. **Both are kept**, the
round goes read-only, and it says the agent moved on. They are not sent — the agent is not waiting for
them. Discarding an unfinished paragraph because a new round arrived would be the worst thing this pane
could do, and the drafts are already keyed by question id on a model that outlives a pane switch.

### An open round is on the home screen
[[ADR-120 The Empty Screen Is A Home]]'s *what needs you* gains a row for a session with an open round:
the session's name and **"6 questions waiting"**. Clicking it opens that session, fronts the Grill pane
**and gives it the keyboard** — user-initiated navigation is exactly the case where ADR-131's rule
allows the pane to take focus, as against a round arriving while the reader is mid-sentence.

ADR-131 claimed this in its Consequences and never built it; `waitingItems` reads `tab.state.isWaiting`
from the hooks and knew nothing about rounds. It matters most after a relaunch, when rounds persist but
[[ADR-079 Panel Tabs]] restores no panes, so an open round is otherwise invisible until someone reopens
that session's tab.

### The transcript parser is dropped
ADR-131 held a `Stop`-hook parser in reserve for a turn where the model printed a round and skipped the
tool. It is **out of scope**, on record beside the skill fork as the escalation if the model ever
drifts. Two things decided it: the instructions layer was verified reaching a live session's system
prompt, which is far harder to miss than a tool description; and a parsed round is freeform-only, so the
parser's failure mode is a pane that appears and has silently lost the multiple choice — worse than a
pane that does not appear.

### The terminal copy is abbreviated
ADR-131 had the agent write each round out in full as well as posting it, so "the terminal stays the
record". Checking the transcript showed that is only half true: the tool call's input is in the JSONL
with every body, so the **machine** record is complete from the tool call alone. Only a human reading
the scrollback needs the prose. So the agent writes an **abbreviated** round — titles and
recommendations, no bodies — which halves the output and keeps the scrollback scannable. The tool's
description says so.

## Consequences
- `GrillPane.swift` is rewritten rather than edited: the flat row list, the card's fold and the
  whole-round scroll all go, and the strip, review step and rounds menu are new. `GrillPaneModel` gains
  the wizard's position and whether the review step is showing.
- Untouched, and deliberately so: `ClinicCore/Grill/`, `GrillAnswerComposer`, the models, the tool
  handler, `GrillAnswerField`, the shim's instructions, and all 32 tests. The rework is presentation.
- Two shapes exist for a round — with and without the strip and review — which is one more than
  ADR-131 had. The one-question case is the cheaper of the two, so this costs a branch, not a screen.
- "Answered" now has to mean the same thing to the strip, the review and *Accept all*; they all read
  `GrillRound.answeredCount`'s rule that a skip counts.
- The pane can now show a round the reader cannot act on — replayed, superseded, or already sent — so
  every control has a disabled state that says why rather than simply not working.

## Corrections
Two bugs this rework walked into, both found by driving it rather than by reading it:

1. **`⏎` contradicted the hint sitting above it.** On a multi-select question — which deliberately does
   not advance when a box is ticked — `⏎` fell through to "start typing", because the rule was written
   as *recommendation or type*. The hint under the choices said "⏎ or ⇥ when you are done" while `⏎`
   opened the text field. `⏎` now means "I am done with this question" in whichever way this question
   can be done: take the recommendation, else move on from an answer already given, else type.
2. **Picking a round from the rounds menu undid itself.** `reset()` cleared `replayingRoundId`, and it
   runs from the `onChange` that fires whenever the round on screen changes — so selecting a round
   changed `current`, which reset the wizard, which cleared the selection, which changed `current`
   back. `reset()` now owns only the wizard's position; the replay is set and cleared explicitly, and a
   newly arrived open round clears it, because the pane's job is to show what is waiting.

## Verification
Built and driven in an isolated smoke instance (its own `CLINIC_APP_SUPPORT`; `~/.claude` read as
usual, never written), with an input driver that **refuses to act unless the smoke Clinic is
frontmost** — added after a stray keystroke reached another app during this session.

- **The wizard**: one question with its body in full, no strip on a one-question round; `⏎` accepted
  and advanced, pip filling as it went; a multi-select took `1` and `3` without advancing and then
  advanced on `⏎`; `s` skipped; no wrapping (Back disabled on the first question).
- **Accept all** filled three recommendations and landed on Q3 — the first question that still had no
  answer — taking the header to *4 of 6* and disabling itself.
- **The review step** listed all six answers in the composer's own words, `⏎` on a row jumped back to
  its question, and **`⌘⏎` sent from a question rather than from review**, pasting the block verbatim.
- **Supersede and replay**: posting over an open round left it `superseded` with exactly one round
  open; the rounds menu listed *waiting / superseded / sent* newest first; replaying the superseded
  round showed it read-only under "The agent moved on to the next round. Anything you entered here was
  kept, but not sent," with only *Back to the open round* in the footer.
- **Persistence and the home screen**: after a relaunch the footer chip read *Grill (2)* with the panel
  closed, and a second window's *Needs you* carried "clinic · 2 questions waiting" with the flame glyph.

450 ClinicCore tests pass and `make build` is clean. Smoke instance and its App Support removed;
`com.r0adkll.clinic` gained no keys.
