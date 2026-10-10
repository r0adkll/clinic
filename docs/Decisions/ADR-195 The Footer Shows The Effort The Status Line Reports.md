---
status: accepted
date: 2026-10-10
supersedes: "the effort source in [[ADR-064 Model and Effort Switching]] (the transcript's `effort` field winning over the level Clinic remembered)"
amends: "[[ADR-157 The Status Line Reports Context]] (the footer reads the report as the card already did)"
tags: [adr, ui, sessions, bug]
---
# ADR-195: The footer shows the effort the status line reports

## Context
User (2026-10-10): *"Looks like the model's effort never really renders in our footer bar"*

The footer's effort chip read only `Tab.effort`. Clinic sets that in two cases: a session launched with
`--effort`, and a level picked from the chip itself. A session started at the CLI's default never has it,
so the chip said *Effort* for the session's whole life. A level changed by typing `/effort` never reached
it either. [[ADR-064 Model and Effort Switching]] expected the transcript's `effort` field to correct it,
but transcripts do not carry one.

[[ADR-157 The Status Line Reports Context]] already receives the live level. In 2.1.296 the status line
input has `effort: { level }` whenever the model takes effort. The level is resolved, so a session on its
default still names one (`kE(…) ?? "high"`, then the model's own default). It re-runs on `effortValue`
changes, so a typed `/effort` reaches it too. The session card read it, and the footer never did.

## Decision
- `Tab.liveEffort` is the status line's level, else `Tab.effort`. The footer chip and the card's meta line
  both read it, so they cannot disagree.
- `Tab.effort` stays as the fallback for a session with no report: an attached one, or one whose first
  status line has not arrived. A model that takes no effort sends no level, so its chip keeps the launch
  flag or reads *Effort*.

## Consequences
- Verified in Clinic Dev on Sonnet 5.5 with no `--effort`: the chip reads *Medium* where it read *Effort*.
  Picking *Low* from it typed `/effort low`. The CLI's banner changed to *Sonnet 5.5 with low effort*, and
  the chip read *Low*.
- Picking a level from the chip briefly shows the old one, until the CLI answers `/effort` with a new
  status line.
- The CLI answers `/effort` with *saved as your default for new sessions*: it writes
  `modelSettings.<model>.effortLevel` into `~/.claude/settings.json`, as `/model` does
  ([[ADR-064 Model and Effort Switching]]). A footer switch is never local to the session. The
  verification run wrote `claude-sonnet-5-5: low` into the user's settings this way.
- Not changed here: the model chip still read `Tab.model`, which says *Model* until the transcript names one,
  though the status line has the model from the start. Fixed in
  [[ADR-196 The Footer Names The Model The Status Line Reports]].
