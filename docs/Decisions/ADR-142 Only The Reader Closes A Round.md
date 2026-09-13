---
status: accepted (built 2026-09-12)
date: 2026-09-12
supersedes: "[[ADR-131 The Grill Pane Answers A Round]] (answered-elsewhere), [[ADR-132 The Grill Pane Is A Wizard]] (supersede)"
tags: [adr, ui, panel, grill, milestone-4]
---
# ADR-142: Only the reader closes a round

## Context
User (2026-09-12): *"Often when doing grilling sessions background agent work is kicked off and
subsequent sets of questions or new rounds come in while you might be answering another round of
questions. Currently, the pane detects this and 'closes' the pane as sent even though it never was."*

Two mechanisms take an open round away from the reader while they are answering it, and both are
[[ADR-131 The Grill Pane Answers A Round]]'s.

**Any prompt at all marks the round answered in the terminal.** `UserPromptSubmit` is wired straight to
`markGrillRoundsAnsweredElsewhere`, with a comment that preserves the faulty step:

> Send marks the round sent synchronously before the paste reaches the CLI, so a round still open here
> was not ours.

That much is true. What does not follow is that the reader *answered* it. A prompt is submitted when a
background agent is kicked off, when an automation fires, when `/model` or `/effort` is typed
([[ADR-064 Model and Effort Switching]]), when a run sends *Fix with Claude* ([[ADR-122 Projects Have Run Configurations]]),
when the pull request panel sends to the session — or when the reader types anything unrelated. Every
one of those closed the round they were working on and told them they had answered it in the terminal.

**A new round supersedes the one being answered.** [[ADR-132 The Grill Pane Is A Wizard]] justified
that:

> the footer acts on *one* round, and two open rounds would give it two Sends with no way to say which
> Send meant which round.

That premise no longer holds. [[ADR-141 The Title Is The Round Picker]] made the title a picker, and the
footer already acts on whichever round is **on screen** — `footer(for:)` takes the displayed round and
`send` refuses one that is not open. The reason supersede existed was dissolved by a later decision, and
nobody went back to check.

## Decision

### A round closes when the reader closes it, and at no other time
Send and Discard. Nothing else. The `UserPromptSubmit` wiring goes, and with it
`markGrillRoundsAnsweredElsewhere`.

A reader who answers a round in the terminal instead will find it still waiting in the pane, and can
discard it. That is a small annoyance with an obvious remedy, and the price of never being wrong; the
alternative was being wrong often, silently, and in the middle of someone's work.

### Rounds no longer supersede one another
Several rounds may be open at once. The title picker moves between them, the footer acts on the one you
are looking at, and each is sent on its own. The supersede rule solved a problem the pane no longer has.

### A new round never takes the view from a round you have started
If the round on screen is open and the reader has begun it — any committed answer, any draft — a newly
posted round does not change what they are looking at. They are told the usual ways (the notification,
the pane's chip count, the picker), and they move when they are ready.

If they have not begun, the new round shows: it is the thing that now needs them, and nothing is lost by
going there. This is [[ADR-131 The Grill Pane Answers A Round]]'s focus rule applied one level up —
never interrupt work in progress, and never *silently*.

### The two dead outcomes stay in the model
`answeredElsewhere` and `superseded` are no longer produced, but remain in `GrillRound.Outcome` so that
state files written before this decision still decode, and so their rounds keep reading correctly in the
history list. Nothing new will ever carry them.

## Consequences
- Counts are sums now: the pane's chip and the home screen's *what needs you* add up the unanswered
  questions across every open round rather than reading one.
- `replayingRoundId` becomes `viewingRoundId` — it no longer means "I am looking at history", it means
  "this is the round I chose", which may be open.
- A session can accumulate open rounds if the reader never sends or discards them. They are visible in
  the picker and counted on the home screen, so they nag rather than vanish — which is the right way
  round, and Discard is one press.
- The pane can no longer tell the reader "you answered this in the terminal", because it never actually
  knew that. It was the only place the pane claimed to know something about the reader's intent.

## Verification
Driven in a smoke instance through the accessibility tree, with hook payloads written straight to
`hook.sock` by `clinic-hook` — which is how the CLI delivers them, so the path under test is the real one.

- **An unrelated prompt no longer closes a round.** With round 1 part-answered (one accepted
  recommendation), a `UserPromptSubmit` carrying *"go do something unrelated"* left it `open` with its
  answer intact. That payload is exactly what a background agent, an automation or `/model` produces,
  and before this change it marked the round answered in the terminal.
- **Rounds no longer supersede.** Posting a second round left both `open`, the first keeping its answer.
- **A begun round keeps the view.** After accepting a question in round 1, posting round 2 left the
  *Accepted* badge on screen — the reader stayed where they were working.
- **An un-begun round does not.** `⎋` moved to round 2 (nothing answered); posting round 3 then left
  three rounds open and the view followed, since nothing was in progress.
- **Counts sum**: the pane's chip read `Grill (7)` with 3 unanswered in round 1 and 4 in round 2, then
  `Grill (11)` with a third.

Three ClinicCore tests asserted the behaviour this ADR removes and were rewritten rather than deleted:
a new round now leaves the one before it open, a part-answered round keeps its answers when another
arrives, and discarding one round does not change another. 456 tests pass and `make build` is clean.
