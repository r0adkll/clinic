---
status: accepted
date: 2026-09-07
tags: [adr, terminal]
---
# ADR-009: Terminal Configuration Source

## Context
Clinic's terminals could read the user's Ghostty config, ship an opinionated config, or layer both. libghostty exposes `ghostty_config_load_default_files` and per-key overrides.

## Decision
Read the user's Ghostty config if present, then apply Clinic-specific overrides for the few keys that conflict with the app's own shortcuts or layout.

## Consequences
- Zero setup for existing Ghostty users; theme and font match their standalone terminal.
- The override list is small, explicit and documented in Architecture.
