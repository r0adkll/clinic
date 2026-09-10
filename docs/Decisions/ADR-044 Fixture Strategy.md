---
status: accepted
date: 2026-09-07
tags: [adr, testing]
---
# ADR-044: Fixture Strategy

## Context
Real transcripts contain prompts, code and account ids; the repo is public.

## Decision
Synthetic fixtures built by a Swift builder in the test target, covering each record type and edge case. Real transcripts stay local as gitignored regression inputs.

## Consequences
- The builder evolves with the reader; a new record type means a builder method and a test.
