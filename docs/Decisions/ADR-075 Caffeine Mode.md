---
status: superseded by ADR-119
date: 2026-09-08
tags: [adr, ui, milestone-3]
---
# ADR-075: Caffeine Mode

> **Partly superseded by [[ADR-119 Caffeine Persists And Can Wait For Agents]]** (2026-09-10).
> The assertion and its toggles stand. *Not persisted* is reversed, because each relaunch dropped the
> assertion without the user noticing. The automatic mode the consequence deferred now exists as
> *Agent Based*.

## Context
Collins' caffeine toggle inhibits suspend so long runs finish while the user is away. On macOS the equivalent is a power-management assertion.

## Decision
- A toolbar toggle (cup icon) and View → *Caffeine Mode* (unbound by default, rebindable) hold `ProcessInfo.beginActivity([.idleSystemSleepDisabled])` while on; the display may still sleep. The status item menu mirrors the toggle so it works while the window is hidden ([[ADR-069 Keep Running and Quit Behaviour]]).
- Not persisted: it is off on every launch, and the assertion ends with the process.

## Consequences
- No automatic mode (on while a session works) — revisit if wanted.
