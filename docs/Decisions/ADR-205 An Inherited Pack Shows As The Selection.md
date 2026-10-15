---
status: accepted (built 2026-10-15)
date: 2026-10-15
amends: "[[ADR-202 The Composer Picks A Session's Sound Pack]] (what the pill shows), [[ADR-204 An Automation Has A Voice]] (what the Voice row shows)"
tags: [adr, sounds, composer, automations]
---
# ADR-205: An inherited pack shows as the selection

## Context
User (2026-10-15): *"On the new session page, if a session is inheriting a sound pack from the project (like
one explicitly set) then it should just show that as selected instead of automatic I think."*

[[ADR-202 The Composer Picks A Session's Sound Pack]] made the composer's pill read *Auto* until a pack is picked
for the session, with the menu's first row saying what Automatic means: "Automatic (GLaDOS, from Campfire)". A
project's pack is a choice someone made, though. Reading *Auto* over it hides that choice behind a word that
sounds like nobody made one.

## Decision
- **A pack a new session inherits by someone's choice is shown as the selection.** That is the parent's
  pack, for a child, or a pack set on the project.
  - The pill reads the pack's name, untinted, since nothing was changed here.
  - The menu's first row is that pack, ticked: "GLaDOS (from Campfire)". It replaces *Automatic*, and the pack
    is not repeated in the list below.
  - Picking another pack overrides it for this session and tints the pill. Picking the inherited one again
    goes back to following it: nothing is recorded for the session, so a later change to the project's pack
    still reaches it.
- **The default and the rotation still read *Automatic*.** Neither was chosen for this project, and a rotation
  has not drawn until the session sounds.
- **The automation editor's Voice row follows the same rule**, for its project's pack.
- `SoundPackStore.inheritedPack(project:parent:)` names that pack and where it comes from. Nothing is drawn to
  answer.

## Consequences
- The session's own *Sound Pack ▸* menu ([[ADR-201 Projects And Sessions Choose Their Sound Pack]]) is unchanged.
  Its *Automatic (GLaDOS, from Campfire)* is about a running session, whose choice is already resolved.
- *Use for Every Session in ‹project›* is offered only for an override, since the inherited pack already is.

## Verification
- `make build` and the Clinic Dev build pass.
- **Checked by the user in Clinic Dev** (2026-10-15): *"It works!"* My own scripted check had been stopped
  partway, because the user had their own Clinic Dev open (pid 39602); the second instance was quit.
- Manual check:
  1. Give a project a pack from its *Sound Pack ▸* menu.
  2. Open that project's composer: the pill reads the pack's name, and its menu ticks "‹pack› (from ‹project›)".
  3. A project with no pack of its own still reads *Auto*.
