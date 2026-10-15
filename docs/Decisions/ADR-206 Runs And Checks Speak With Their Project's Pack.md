---
status: accepted (built 2026-10-15)
date: 2026-10-15
amends: "[[ADR-201 Projects And Sessions Choose Their Sound Pack]] (moments with no session), [[ADR-204 An Automation Has A Voice]] (a run that never started)"
tags: [adr, sounds, runs, pull-requests, automations]
---
# ADR-206: Runs and checks speak with their project's pack

## Context
User (2026-10-15): picked *"Runs and PR checks use the default pack, not their project's"* from the follow-ups.
[[ADR-201 Projects And Sessions Choose Their Sound Pack]] left it open: a pack is resolved for a session, and a
run, a PR check with no session behind it, or an automation that never started has none, so each spoke with the
default even in a project with a pack of its own.

## Decision
- **A moment with no session names its project**, and speaks with that project's pack, else the default.
  - A run: its `projectPath`, both when it is announced and when it is on screen and only voiced.
  - A PR check: the project of the tab whose pane shows the pull request. A pane owned by a session still
    resolves through that session, as before.
  - An automation: its target's project.
- **There is no rotation draw without a session.** A draw is kept per session for its life; a run has no life to
  keep it for. With no project pack, the default speaks.
- **An automation that never started speaks with its own pack** when it has one, then its project's. This
  closes the edge [[ADR-204 An Automation Has A Voice]] left.
- `SoundPackStore.voice`, `TabStore.voice` and `TabStore.notify` take `project:` and `pack:`. Both are ignored
  when there is a session.

## Consequences
- `PRStore.OpenPR` carries the tab's project, and its router passes it beside the session.
- `AutomationsModel.router` passes a `Route` (session, project, pack) instead of a bare session.

## Verification
- `make test`: ClinicCore 692 pass, one new: with no session, the project's pack, then the default, and the
  rotation passed over.
- `make build` passes.
- **Not driven in the app.** The user's own Clinic Dev was open. Manual check: give a project a pack, start one of
  its run configurations, switch to another tab, and hear the project's pack say the run ended.
