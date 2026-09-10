---
status: accepted
date: 2026-09-07
tags: [adr, scope, collins]
---
# ADR-002: Collins as the Milestone 1 Spec

## Context
Clinic reimplements [Collins](https://github.com/episode6/collins) natively on macOS. Collins is ~37k lines of Python/GTK with a sidebar, terminal, git page, PR page, editor, composer, MCP tools, notifications and usage panel (see [[Collins]]). We need a rule for how closely to track it.

## Options
- (a) Faithful port of feature set and layout, deviating only for macOS idiom
- (b) Collins is the starting spec; own additions and cuts after milestone 1
- (c) Merely inspired by Collins

## Decision
(b). Collins's feature inventory is the milestone 1 spec so scope is not invented. After milestone 1 lands, Clinic diverges freely.

## Consequences
- The [[Collins]] research note is the backlog seed; milestone slicing is a separate decision.
- Collins is GPL-3.0. Clinic is a clean-room reimplementation: behaviour and layout may be studied, no code or assets are ported. See [[ADR-011 Repo Naming and License]].
