---
status: accepted (sidebar scope superseded by ADR-048)
date: 2026-09-07
tags: [adr, sessions, scope]
---
# ADR-028: Sessions Started Outside Clinic

## Context
A session launched from a plain terminal has no Clinic hooks; its state is invisible.

## Options
- (a) Show as inactive with last-activity time only
- (b) Opt-in global hook in `~/.claude/settings.json` (breaks [[ADR-018 Claude Data Write Policy]])
- (c) Poll `claude agents --json` for background sessions

## Decision
(a) for milestone 1. (b) is a milestone 2 candidate requiring its own ADR. (c) is deferred with background agents.

## Consequences
- Clear visual distinction between 'open in Clinic' and 'known from disk'.
