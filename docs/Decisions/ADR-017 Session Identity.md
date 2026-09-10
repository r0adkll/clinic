---
status: accepted
date: 2026-09-07
tags: [adr, architecture, sessions]
---
# ADR-017: Session Identity

## Context
Collins polls the transcript directory to learn a new session's id. Verified locally: `--session-id <uuid>` creates a new session with that id, and the `SessionStart` hook payload carries `session_id` and `transcript_path` (correct even under `-w`, where the transcript lands under the worktree's encoded cwd).

## Decision
Clinic pre-generates a UUID for every new session and passes `--session-id`. Resume passes the existing id. `SessionStart` confirms identity and transcript path. No directory polling for identity. Directory watching remains only for discovering sessions created outside Clinic.

## Consequences
- A tab knows its session id before the CLI writes anything; no placeholder rows.
- Fork (`--fork-session`) produces a new id reported by `SessionStart` with `source: fork`.
