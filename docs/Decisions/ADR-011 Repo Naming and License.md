---
status: accepted
date: 2026-09-07
tags: [adr, release, scope]
---
# ADR-011: Repo Naming and License

## Context
Collins is GPL-3.0. Clinic wants a permissive license.

## Decision
Public GitHub repo `r0adkll/clinic`, bundle id `com.r0adkll.clinic`, MIT license. Public from the first commit, as with Ditto. Clean-room reimplementation: no Collins code or assets.

## Consequences
- App name 'Clinic', data under `~/Library/Application Support/Clinic`.
- Research notes may describe Collins behaviour in detail; implementation is written fresh.
