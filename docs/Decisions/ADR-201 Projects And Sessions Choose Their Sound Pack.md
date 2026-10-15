---
status: accepted (built 2026-10-14)
date: 2026-10-14
amends: "[[ADR-199 Clinic Plays OpenPeon Sound Packs]] (phase 2: who speaks with which pack), [[ADR-200 Sounds Are Browsed By Language, Franchise, Tags And Quality]] (the pack page's action bar)"
tags: [adr, sounds, projects, sessions, notifications]
---
# ADR-201: Projects and sessions choose their sound pack

## Context
User (2026-10-14): *"Okay, lets continue"*, after [[ADR-200 Sounds Are Browsed By Language, Franchise, Tags And Quality]].

[[ADR-199 Clinic Plays OpenPeon Sound Packs]] decided, in its third question, the order a session's pack comes
from:
1. the session's own;
2. its project's;
3. a pick from a rotation that the session keeps;
4. the default.

A child session takes its parent's. Phase 1 built only the default. This builds the rest, and phase 2's other
item: the line a pack said, shown on the notification it stood in for. Nothing here needed a new decision from
the user. What follows is where those rules live and how they read.

## Decision
- **Kept in `state.json`**, beside the other per-project choices (`openInByProject`): `soundPacks` holds
  `byProject` (path → pack), `bySession` (session → pack the user chose) and `drawn` (session → the pack it
  drew from the rotation). The rotation itself is a preference, `SoundSettings.rotation`, beside the default.
- **Resolution** (`SoundPackAssignments.resolve`, pure and unit-tested):
  1. The session's own pack.
  2. Else the nearest ancestor's own pack.
  3. Else, for a child, whatever the root of its family speaks with. The family outranks the child's
     project: a child started in another project still sounds like its parent.
  4. Else the project's pack.
  5. Else the session's draw from the rotation.
  6. Else the default.

  A pack that is no longer installed falls through to the next step.
- **A draw happens once**, the first time a session needs a pack and the rotation applies. It picks the
  rotation pack that the fewest live sessions are speaking with, breaking a tie at random, so sessions running
  side by side sound different. The draw is recorded for the session's life, resumes included. A child does
  not draw: its root does. A draw that has left the rotation is drawn again. Draws for sessions that no
  longer exist are pruned once there are more than 400.
- **A view never draws.** Menus ask with `draw: false` and say *Automatic*, rather than a side effect of
  opening a menu giving a session its voice.
- **Where it is set:**
  - *Sound Pack ▸* in a project's menu and a session's menu: *Automatic (…)*, saying what that currently
    means ("Orc Peon, from clinic", "GLaDOS, from the rotation"), then every installed pack, ticked, then
    *Browse Sound Packs…*.
  - On a pack's page, *Use for Project ▸* lists every project, ticked where this is its pack, and *Add to
    Rotation* / *In Rotation ✓*. Both need the pack installed. The status beside them says where the pack is
    heard: Default, In the rotation, the projects using it.
  - The Sounds footer shows *Default: ‹pack›* and *Rotation · N*, a menu of installed packs to tick, and
    *Clear Rotation*.
  - List rows add *in rotation* and the projects using the pack.
- **Captions.** When a pack line stands in for a notification's sound, the history entry records it as
  *‹Pack›: “‹line›”*. The in-app card and the history panel show it under the body, with a speaker glyph, in
  the accent. The system notification is unchanged.
- `TabStore.voice` now returns what was spoken (`covered`, `caption`) rather than a flag.

## Consequences
- Runs, PR checks and other moments with no session still speak with the default. A run belongs to a project,
  and could take the project's pack later.
- The session list does not show which pack a session speaks with. The session's menu says.
- The draw is recorded the moment a session first sounds. A session that never makes a sound never draws.

## Verification
- `make test`: ClinicCore 683 pass, five of them new:
  - the order of resolution;
  - a child taking the nearest ancestor's own pack, and its family outranking its project;
  - the rotation drawn once, kept, and redrawn when it leaves the rotation, with the root drawing for a child;
  - draws spreading to the least-used pack;
  - old `state.json` decoding, and pruning.
- Clinic Dev, synthetic hooks, with Peon as the default:
  - With the scratch project given GLaDOS, the `sounds` log shows `[glados for <session>]` for the start and
    the permission request.
  - With the project's pack cleared and the rotation set to The Abbot and ITYSL, the log shows `session …
    drew itysl from the rotation` once, then `[itysl for …]` for both lines, and `state.json` holds
    `drawn: {<session>: itysl}`.
- **Not looked at:** the menus, the footer's Rotation menu and the caption on the card. Clinic Dev's window
  was on another Space for these runs, so neither accessibility nor capture could reach it.
