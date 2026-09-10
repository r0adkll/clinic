---
status: accepted
date: 2026-09-07
tags: [adr, architecture]
---
# ADR-021: Persistence

## Decision
Clinic state (names, favorites, archived, project order, window geometry, last session, per-session overlays) is one Codable JSON file under Application Support, written atomically and debounced. No SwiftData or SQLite.

## Consequences
- Revisit if attachments or notification history ever need querying.
- Transcript-derived caches (head/tail parse results keyed by path, mtime, size) live in a separate cache file so state stays small.
