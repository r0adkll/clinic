---
status: accepted (built 2026-10-15)
date: 2026-10-15
amends: "[[ADR-095 Automations]] (the editor's Behaviour rows, and how a run's outcome sounds), [[ADR-201 Projects And Sessions Choose Their Sound Pack]] (a session's pack can come from its automation)"
tags: [adr, sounds, automations]
---
# ADR-204: An automation has a voice

## Context
User (2026-10-15): *"Let's do Automations now"*. This was the follow-up named in
[[ADR-202 The Composer Picks A Session's Sound Pack]]: a scheduled session whose finish line says which one ran.

How automations sound today:
- An automation fires `claude --bg` ([[ADR-095 Automations]]), so a run is a background agent with no tab. Its
  hooks reach `TabStore`, which ignores sessions it has no tab for, so none of a run's hook witnesses ever voice.
- The one sound an automation makes is its outcome notification (finished, failed, stalled, could not start),
  which went through `TabStore.notify` with no witness. It therefore played the notification sound
  ([[ADR-097 Notification Sounds]]) and never a pack line.
- A run learns its session id only at `SessionStart`, by prefix match, because `--bg` refuses `--session-id`.

## Decision
- **An automation has an optional pack**, `Automation.soundPack`. Nil is Automatic. Automations saved before
  it decode as Automatic.
- **The editor's Behaviour grid gains a Voice row** between *Missed runs* and *Give up after*: *Automatic (…)*,
  saying what that is ("Orc Peon, from clinic", "Peon, the default", "no pack"), then each installed pack.
  It is shown on the same terms as the composer's pill: sounds on and at least two packs installed. With no
  pack at all, the wording is "no pack", not "silent": the notification sound still plays.
- **A run's session takes the automation's pack** the moment it is bound at `SessionStart`, as its own
  (`soundPacks.bySession`). It then outranks the project, the rotation and the default for that session, and
  opening or resuming the run later keeps the voice.
- **The outcome speaks**, with two new witnesses in the Events table's Clinic section:
  - `automationFinished` → `task.complete`;
  - `automationFailed` → `task.error`, for a failure, a stall, or a launch that did not start.

  A skipped run says nothing out loud.
- **The voice rides on the notification.** It speaks only when the automation's Notify policy notifies.
  The default, *Failures and stalls only*, keeps a successful run quiet. That matches what the user asked the
  automation to do, and stops nightly jobs greeting the morning one by one.
- A run whose launch failed has no session, so it speaks with the default pack rather than its own. This is
  an edge, and is left so.

## Consequences
- The router from `AutomationsModel` to `TabStore.notify` now carries the witness.
- `AutomationsModel` holds a weak `SoundPackStore`, set by the app, to record the pack when a run is bound.
- A background run's start, prompt and turn-end hooks still do not voice: the run has no tab, and an
  unattended job announcing its own beginning is noise.

## Verification
- `make test`: ClinicCore 691 pass. A new test covers an automation saved before the field decoding as
  Automatic, a pack surviving the round trip, and the two witnesses' categories.
- Clinic Dev, with the editor opened by `-ClinicAutomationDraftOnLaunch blank`, captured: the Voice row sits
  in the Behaviour grid, reading *Automatic (no pack)* with no default set.
- **Not driven:** a real scheduled run. It would cost a model turn, and nothing new would show beyond what is
  covered: binding is the existing prefix match plus one `setPack`, and the outcome goes through
  `TabStore.notify`'s witness path, verified end to end for ADR-199 and ADR-203.
