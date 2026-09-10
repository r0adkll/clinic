---
status: superseded by ADR-105
date: 2026-09-07
tags: [adr, process]
---
# ADR-012: Process

## Context
Ditto's process (grilling rounds → ADRs → Design Tree → dated Log entries → Backlog → milestone-based delivery with a thin vertical slice first) is working.

## Decision
Mirror Ditto exactly. Vault at `~/SoftwareProjects/vaults/clinic`.
(The vault location is superseded by [[ADR-105 The Vault Lives In The Repo]]; it is now `docs/` in the repo. The process below stands.)

## Consequences
- No implementation before the design tree frontier is empty and the author confirms shared understanding.
- Every working session ends with a Log entry; every settled decision is an ADR.
