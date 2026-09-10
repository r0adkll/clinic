---
status: accepted
date: 2026-09-07
tags: [adr, hooks, policy]
---
# ADR-047: No opt-in global hook

## Context
[[ADR-028 Sessions Started Outside Clinic]] left open a milestone 2 option: writing a hook into `~/.claude/settings.json` so sessions started from a plain terminal report state to Clinic. It would have broken [[ADR-018 Claude Data Write Policy]].

## Decision
No. The user declined on 2026-09-07. Clinic only knows the live state of sessions it launched. `~/.claude` stays read-only.

## Consequences
- Together with [[ADR-048 Clinic-Owned Sessions]], this makes "a session Clinic started" the unit the sidebar is built around.
- Removed from the [[Backlog]].
