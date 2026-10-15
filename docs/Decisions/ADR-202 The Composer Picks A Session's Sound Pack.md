---
status: accepted (built 2026-10-14)
date: 2026-10-14
amends: "[[ADR-082 New Session Screen Composer]] (a voice pill in the control bar), [[ADR-201 Projects And Sessions Choose Their Sound Pack]] (a session's pack can be set before it starts)"
tags: [adr, sounds, composer, new-session]
---
# ADR-202: The composer picks a session's sound pack

## Context
User (2026-10-14): *"Should we let user's pick installed sounds packs in the new session screen?"*

Asked for a verdict, I said yes, with constraints, and the user agreed: *"Yes, that sgtm!"*

The case for it:
- The composer is the one moment the reader knows what a session is for.
- Without it, a session's pack can only be set from its menu once it is running. By then it has played its
  start line in another voice, and possibly drawn from the rotation.
- The rotation gives sessions running side by side different voices, but at random. The composer lets the
  reader choose: "this one is GLaDOS".
- Clinic assigns a session's id before launch ([[ADR-017 Session Identity]]), so a pick can be the session's
  own pack before its first sound.

The case for restraint: the control bar (model, effort, worktree and branch, or fork and report for a child)
is in front of every new session, and most sessions should just speak with their project's pack or the
rotation.

## Decision
- **A voice pill in the composer's control bar**, after the worktree and branch, or after fork and report for
  a child. It reads *🔊 Auto*, or the chosen pack's name tinted in the accent like the other pills when
  changed. It is **shown only when sounds are on and at least two packs are installed**; with fewer, there is
  nothing to choose.
- **Its menu:**
  - *Automatic (…)*, saying what that will be: "Orc Peon, from Campfire", "GLaDOS, from its parent", "a pack
    from the rotation", "Peon, the default". Nothing is drawn to say so.
  - Every installed pack, ticked.
  - *Hear It*, which plays a greeting from the chosen pack, or from the one Automatic will give when that is
    known before a draw.
  - *Use for Every Session in ‹project›*, shown once a pack is picked. It sets the project's pack and puts the
    pill back to Automatic, since the project now gives it.
  - *Browse Sound Packs…*.
- **The pick is not remembered.** Model and effort are remembered per project; a remembered voice would
  quietly override the project's pack and the rotation for every later session. A project's voice already
  lives in its menu, and the composer offers the shortcut to it. The pick lives on the draft in memory and is
  not saved with an unsent composer.
- **On send**, the pick becomes the session's own pack (`soundPacks.bySession`) as the session is launched,
  before its `SessionStart`. That covers a fresh session, a worktree session (including one made from a named
  branch), and a spawned child. A fork learns its id only when the CLI reports it, so the pick waits on the tab
  (`pendingSoundPack`) and is recorded when the fork is adopted, as its parent link is.
- **Not on the new-session sheet**, which only picks the project ([[ADR-121 The New Session Sheet Picks A Project]]).

## Consequences
- A pack chosen here outranks the session's family, project and rotation for that session, like a pack chosen
  from its menu ([[ADR-201 Projects And Sessions Choose Their Sound Pack]]). Changing it later is done there.
- Automations do not have a pack yet. A scheduled session's finish line naming which one ran is the obvious
  follow-up.

## Verification
- `make test` passes, and Clinic Dev builds.
- In Clinic Dev with four packs installed and a rotation set, the Campfire composer was opened by
  accessibility and captured. The control bar shows *Auto · Auto · Worktree · 🔊 Auto*, and the pill is labelled
  "Sound pack, Automatic".
- **Not looked at:** the pill's menu. A SwiftUI menu in a background app does not open on an accessibility
  press, and bringing Clinic Dev forward would have taken the user's screen. The launch path that records the
  pick was not driven either.
- Manual check:
  1. In Clinic Dev, open a project's composer and pick a pack from the pill.
  2. Send, and look at the session's *Sound Pack ▸*: the pack is ticked.
  3. Its start line is in that voice.
