---
status: accepted
date: 2026-09-07
tags: [adr, build]
---
# ADR-006: Platform and Language

## Context
Machine runs macOS 26.6 with Xcode 26.2. Ghostty main requires macOS 14+. Going macOS-26-only buys little for a terminal-centric app and blocks sharing.

## Decision
Minimum macOS 15. Swift 6 language mode with strict concurrency on from the first commit.

## Consequences
- `@MainActor` isolation for everything touching libghostty (its calls must be on the main actor).
- Background scanning and parsing live in actors.
