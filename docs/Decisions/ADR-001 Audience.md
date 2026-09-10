---
status: accepted
date: 2026-09-07
tags: [adr, scope]
---
# ADR-001: Audience

## Context
Clinic can be a personal tool, a personal tool structured for publishing, or a public app from day one. Each implies a different level of polish, onboarding and configurability.

## Options
1. Built for the author's daily use, structured as publishable (public repo, signed/notarized builds, MIT)
2. Public app from day one
3. Private personal tool

## Decision
Option 1, mirroring Ditto's ADR-001. No premature configurability for strangers.

## Consequences
- Milestone 1 optimises for the author's workflow.
- Repo is public and builds are signed from the first release, so publishing later is a non-event.
- See [[Vision]].
