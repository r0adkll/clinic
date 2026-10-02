---
status: accepted
date: 2026-10-02
amends: "[[ADR-131 The Grill Pane Answers A Round]] (a second source of rounds, whose answers return as a tool result and not as a pasted message), [[ADR-177 Hooks Arrive Through A Mod]] (the socket answers a request it holds open; the mod changes one tool call's result)"
tags: [adr, ui, grill, mods]
---
# ADR-179: Claude's questions are answered in the Grill pane

## Context
Second step of the mods work, agreed 2026-10-02 ([[Log]]); user: *"yes start"*. Branch `mods-integration`.

The Grill pane ([[ADR-131 The Grill Pane Answers A Round]]) answers rounds the agent posts through Clinic's
own `ask_round` tool. That tool returns at once and the turn ends; the reader's answers are pasted into the
terminal as their next message. Claude Code's built-in `AskUserQuestion` dialog never reached the pane.

Measured against CLI 2.1.287 in an interactive session driven through tmux:

- A `tool.call` hook matched on `AskUserQuestion` receives the tool's `questions` and `tool_use_id`.
- `next(e)` resolves, once the terminal dialog is answered, to
  `{ result: { questions, answers: { <question text>: <label or typed text> }, annotations }, text }`.
- A hook that returns `{ result: { questions, answers } }` while `next(e)` is still pending closes the
  terminal dialog. The transcript reads *User answered Claude's questions* and the turn goes on.
- A hook's budget counts its own time only. A `$` call in flight is free, a `$.clock.sleep` is not, so
  waiting minutes for a reader has to be a held request, not a polling loop of sleeps.
- The CLI also raises `PermissionRequest` for the dialog.

## Options
- **Replace the dialog**, answering only in Clinic. Rejected: the terminal must keep working on its own, and
  a mod that fails would leave a question nobody can answer.
- **Poll Clinic on a timer from the mod.** Rejected: the sleeps would spend the hook's ten-second budget.
- **A second socket for answers.** Rejected: one socket and one server already carry the mod's traffic.
- **Both at once, first answer wins, over a held request.** Chosen.

## Decision
- **The mod mirrors every `AskUserQuestion`.** It sends `AskQuestion` with the questions and the
  `tool_use_id`, then lets the terminal dialog open and, at the same time, waits on Clinic.
- **The wait is a held `GET /answer?id=<tool_use_id>`** on the hook socket. `HookServer` keeps the connection
  and hands a `HookPoll` to `AskBroker`. With nothing to say after 20 s it answers `204` and the mod asks
  again. `200` carries `{ "answers": … }`. `410` means the dialog is over or the round was discarded, and
  the mod stops waiting.
- **First answer wins.** Answers from the pane become the tool's result, which closes the terminal dialog.
  A dialog answered or dismissed in the terminal is passed through untouched, and the mod sends
  `AskResolved` with what was answered so Clinic can close its copy.
- **The dialog becomes a `GrillRound`** with `source: dialog` and the `toolUseId`. The question's text is the
  title, its helper line the body, its options the choices. An option labelled *(Recommended)* is the
  recommended choice, so `⏎` accepts it. The pane opens and takes the keyboard as for `ask_round`
  ([[ADR-139 A Round Takes The Keyboard]]).
- **Answers are spelled as the dialog would spell them**, keyed by the question's text: a label, several
  labels comma-joined, or the reader's own words. The dialog has no skip, so a question passed over is
  answered *No preference. You decide.*
- **Sending a dialog round types nothing.** `GrillPane.send` hands the answers to the broker. An answer
  given between two polls is kept for the next one.
- **Discarding a dialog round** closes it in the broker. The terminal dialog stays open.
- **A round answered in the terminal** is marked `answeredElsewhere` and records what was chosen there.
- **One notification, worded as a question.** The dialog arrives as a permission request; while a dialog
  round is open Clinic says *N questions waiting in the Grill pane* in place of *Needs permission*.
- **A new smoke key**, `-ClinicEnterAfter <seconds>`, presses Return in the launched session, to answer a
  terminal dialog with nobody at the keyboard.

## Consequences
- A question answered in Clinic no longer ends the turn and starts another. Claude reads the answers as
  the tool's result and carries on.
- `ask_round` is unchanged, and remains the richer form: several paragraphs per question, a round number
  and a topic. The built-in dialog allows four questions of four options.
- On settings hooks (an older CLI, or a mod that did not load) nothing changes: the dialog is terminal-only.
- If Clinic quits while a dialog is open the mod's requests fail three times and it stops waiting. The
  terminal dialog is unaffected.
- The tab reads *needs permission* while the dialog is open, because that is what the CLI reports.
- Verified 2026-10-02 in Clinic Dev on CLI 2.1.287. A session asked one question; the round appeared in
  the pane with *Apple (Recommended)* marked. Pressing *Banana* and *Send* through the accessibility API
  gave the transcript the tool result `"Which fruit do you prefer?"="Banana"`, and Claude replied
  *You chose Banana*. In a second session Return was pressed in the terminal: the trace showed
  `AskResolved` with *Apple (Recommended)* and the round was stored as `answeredElsewhere` with that
  choice. ClinicCore's 614 tests and the mod's 6 pass.
- Not verified: a multi-question or multi-select dialog through the pane, a dialog asked by a subagent,
  the reworded notification, and discarding a dialog round.
