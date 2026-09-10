---
status: accepted
date: 2026-09-07
tags: [adr, architecture, claude]
---
# ADR-003: Claude Code Integration Model

## Context
A session manager can drive Claude Code by (1) running the real `claude` CLI in a PTY and observing state from outside, (2) using the Agent SDK headlessly with a custom chat UI, or (3) a hybrid. Collins uses (1) with no hooks or SDK, detecting state by screen-scraping (OSC 9;4 progress, spinner motion, the `❯` prompt line, process tree). Choosing libghostty implies the CLI runs in a real terminal.

## Options
1. PTY only, screen-scraping for state (Collins)
2. Agent SDK headless, custom UI
3. Hybrid: PTY-driven CLI as the surface, hooks and transcript JSONL for metadata

## Decision
Option 3. The interactive CLI runs unmodified in a libghostty surface. State detection comes primarily from Claude Code hooks reporting to a channel Clinic owns, with JSONL transcript parsing as the source for names, cost, history and as a fallback. Screen-scraping is a last resort, not the design.

## Consequences
- Clinic must inject hooks per launch without editing the user's settings (mechanism: see [[ADR-013 State Detection]] once settled).
- The JSONL reader is a core, UI-free module with its own tests.
- The libghostty surface is a rendering and input host, not a state source.
