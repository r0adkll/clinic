---
status: accepted
date: 2026-09-07
tags: [adr, process, milestones]
---
# ADR-039: Milestone 1 Build Order

## Decision
1. Repo skeleton: XcodeGen, submodule at v1.3.1, xcframework build script, CI.
2. GhosttyBridge + headless smoke test + a window showing one shell. **Risk retirement point.**
3. ClinicCore: JSONL reader with fixtures, state machine, persistence.
4. Hook helper and socket server.
5. Sidebar, new session, notifications.
Each step lands as its own commit series with a [[Log]] entry.
