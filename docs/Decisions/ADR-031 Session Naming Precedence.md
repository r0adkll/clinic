---
status: accepted
date: 2026-09-07
tags: [adr, sessions, ui]
---
# ADR-031: Session Naming Precedence

## Decision
Clinic manual name (milestone 2) > CLI `custom-title` or `-n` name > CLI `ai-title` > first prompt words, truncated. No headless `claude -p` title generation in milestone 1.

## Consequences
- Names update live as the tail scan sees new title records.
