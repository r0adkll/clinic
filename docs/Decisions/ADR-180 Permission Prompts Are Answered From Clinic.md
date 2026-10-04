---
status: accepted
date: 2026-10-04
amends: "[[ADR-066 Attention]] and [[ADR-033 Notification Delivery]] (a needs-permission notification carries Approve and Deny), [[ADR-156 Sessions Can Be Cards]] (the card offers the two answers while it waits), [[ADR-166 Session State Has More Than One Witness]] (the mod's turn end now ends a turn whenever no `Stop` came first)"
tags: [adr, ui, permissions, mods]
---
# ADR-180: Permission prompts are answered from Clinic

## Context
Third step of the mods work, agreed 2026-10-02. User, asked 2026-10-03 how Clinic should answer a permission
prompt: *type into the CLI's prompt*; where the controls go first: *the sidebar card* and *macOS notification
actions*; whether to offer *Yes, and don't ask again*: *no, only Yes and No*.

A mod can decide `tool.check` itself, approving a tool call before the prompt shows. That makes Clinic an
authority over what runs, which the user declined. Measured against CLI 2.1.289 in tmux, with the mod's trace
alongside:

- The prompt offers *1. Yes*, *2. Yes, and always allow …*, *3. No*, with *Esc to cancel*. Pressing the digit
  answers at once.
- `1` runs the tool; `Stop` and `TurnEnd` follow.
- `3` and Esc both end the turn as an interrupt: *Interrupted · What should Claude do instead?*, then
  `TurnEnd` with reason `answer` and neither `Stop` nor `PermissionDenied`.
- The prompt reads key presses. Text committed through the terminal's input-method path, which
  `sendText` uses, was ignored; a synthesized key event was not.

## Options
- **The mod answers `tool.check`.** Rejected by the user: Clinic would approve on its own authority, the
  prompt would be skipped, and a trust rule would be needed.
- **Keystrokes into the prompt.** Chosen. The CLI stays the authority, the prompt shows the answer, and it
  works on either hook transport.

## Decision
- **Approve types `1` and Deny types `3`**, as key events (`GhosttySurfaceView.pressKey`), only while the tab
  is `waitingForPermission` and the prompt is not Claude's question dialog, which the Grill pane answers
  ([[ADR-179 Claude's Questions Are Answered In The Grill Pane]]). Nothing is remembered: *don't ask again*
  is not offered.
- **The card shows the two buttons** under its *Allow Bash …?* line while they apply.
- **The needs-permission notification carries them** as actions. Pressing one answers without bringing
  Clinic forward; clicking the notification itself still reveals the session.
- **A turn still working or waiting when the mod's `TurnEnd` arrives is over.** `Stop` precedes an answered
  turn's end when it comes at all, so a turn that has not moved by then had none: an interrupt, a refusal,
  or a prompt answered *No*. `error` is left to `StopFailure`, which carries the message.

## Consequences
- Deny is the CLI's *No*: the turn ends and Claude waits to be told what to do instead. That is what the
  terminal does, not a Clinic choice.
- Where the prompt's key layout changes, Clinic types the wrong answer. The digits are the CLI's own
  shortcuts and have been stable; the help text on each button says which key it stands for.
- Verified 2026-10-04 in Clinic Dev on CLI 2.1.289, through the accessibility API: *Approve* on the card ran
  `touch` (the file appeared, `Stop` followed, the buttons left); *Deny* on a second session left no file,
  the card read *Ready* and the turn ended on `TurnEnd`. ClinicCore's 615 tests pass.
- Not verified: the notification's Approve and Deny, because Clinic Dev is denied notifications on this Mac;
  the buttons by eye.
