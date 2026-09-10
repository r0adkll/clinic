---
status: accepted
date: 2026-09-07
tags: [adr, architecture, policy]
---
# ADR-018: Claude Data Write Policy

## Context
Collins treats `~/.claude` as read-only except confirmed transcript deletion and a folder-trust write before `-w` launches.

## Decision
Read-only in milestone 1, without exception. No deletion UI. The trust write is deferred until a worktree launch is shown to need it. All Clinic state lives under `~/Library/Application Support/Clinic`.

## Consequences
- Archive, favorites and names are Clinic-side overlays keyed by session id.
- Any future write to `~/.claude` needs its own ADR.
