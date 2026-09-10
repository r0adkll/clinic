---
status: accepted
date: 2026-09-07
supersedes: parts of ADR-013, ADR-028, ADR-029
tags: [adr, sessions, ui, scope]
---
# ADR-048: The sidebar shows sessions Clinic started; discovery becomes import

## Context
Milestone 1 built the sidebar from every transcript under `~/.claude/projects` ([[ADR-029 Discovery and Scanning]]). With dozens of historical sessions per project the sidebar is cluttered out of the box, and those sessions never have live state ([[ADR-047 No Global Hook]]). User feedback 2026-09-07: "stick to Clinic generated sessions".

## Decision
- Clinic keeps a persisted registry of sessions it owns (`ClinicState.ownedSessions`: id → project path, created date). A session enters the registry when Clinic starts it (⌘N) or when the user **imports** an existing one.
- The sidebar lists only owned sessions, grouped by project. Projects come from owned sessions plus explicitly added folders.
- Discovery stays, but as the source for **Import**: ⌘K searches all on-disk transcripts (marked "not in Clinic") and opening one imports it; the project header menu has "Import session…".
- Transcript facts (titles, activity, model) still come from the scanner for owned sessions.

## Consequences
- Fresh installs start empty except for projects the user adds; no surprise clutter.
- Sessions started outside Clinic are one ⌘K away, never lost.
- A hidden preference `ClinicShowDiscoveredSessions` restores the milestone 1 behaviour for comparison.
