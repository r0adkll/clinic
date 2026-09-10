---
status: accepted
date: 2026-09-07
tags: [adr, process, release]
---
# ADR-024: Milestones and Versioning

## Decision
0.x semantic versioning. `0.1.0` is tagged when milestone 1 ([[ADR-013 Milestone 1 Slice]]) is usable daily. One milestone per [[Backlog]] section. Mirrors Ditto's ADR-025.

## Consequences
- No release automation before 0.1.0; ad-hoc signed local builds until the Developer ID exists ([[ADR-010 Distribution]]).
