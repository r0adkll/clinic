---
status: accepted
date: 2026-10-04
amends: "[[ADR-066 Attention]] and [[ADR-033 Notification Delivery]] (a needs-permission notification carries Approve and Deny), [[ADR-156 Sessions Can Be Cards]] (the card offers the two answers while it waits)"
tags: [adr, ui, permissions]
---
# ADR-180: Permission prompts are answered from Clinic

## Context
Built on the `mods-integration` branch and kept when that effort was abandoned
([[ADR-179 Clinic Does Not Ship A Mod]]), because it needs none of it. User, asked 2026-10-03 how Clinic
should answer a permission prompt: *type into the CLI's prompt*; where the controls go first: *the sidebar
card* and *macOS notification actions*; whether to offer *Yes, and don't ask again*: *no, only Yes and No*.

Measured against CLI 2.1.289 in tmux:

- The prompt offers *1. Yes*, *2. Yes, and always allow …*, *3. No*, with *Esc to cancel*. Pressing the digit
  answers at once.
- `1` runs the tool; `Stop` follows.
- `3` and Esc both end the turn as an interrupt: *Interrupted · What should Claude do instead?*, with
  neither `Stop` nor `PermissionDenied`. The terminal witnesses of ADR-166 bring the tab to rest.
- The prompt reads key presses. Text committed through the terminal's input-method path, which
  `sendText` uses, was ignored; a synthesized key event was not.

## Options
- **Decide the permission in Clinic**, through a mod's `tool.check`. Rejected by the user: Clinic would
  approve on its own authority and the prompt would be skipped.
- **Keystrokes into the prompt.** Chosen. The CLI stays the authority and the prompt shows the answer.

## Decision
- **Approve presses `1` and Deny presses `3`**, as key events (`GhosttySurfaceView.pressKey`), only while the
  tab is `waitingForPermission` and the tool asking is not `AskUserQuestion`, whose dialog takes choices.
  Nothing is remembered: *don't ask again* is not offered.
- **The card shows the two buttons** under its *Allow Bash …?* line while they apply, and reads *Has a
  question for you* instead of *Allow AskUserQuestion ?* when the prompt is the question dialog.
- **The needs-permission notification carries them** as actions. Pressing one answers without bringing
  Clinic forward; clicking the notification itself still reveals the session.
- **A smoke key**, `-ClinicEnterAfter <seconds>`, presses Return in the launched session, to answer a terminal
  dialog with nobody at the keyboard.

## Consequences
- Deny is the CLI's *No*: the turn ends and Claude waits to be told what to do instead.
- Where the prompt's key layout changes, Clinic types the wrong answer. The digits are the CLI's own
  shortcuts; each button's help text says which key it stands for.
- Verified 2026-10-04 in Clinic Dev on CLI 2.1.289, through the accessibility API: *Approve* on the card ran
  `touch` (the file appeared, `Stop` followed, the buttons left); *Deny* on a second session left no file
  and the card read *Ready*. Ported to `main` the same day; ClinicCore's 587 tests pass.
- Not verified: the notification's Approve and Deny, because Clinic Dev is denied notifications on this Mac;
  the buttons by eye.
