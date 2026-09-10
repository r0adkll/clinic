---
status: accepted
date: 2026-09-07
tags: [adr, scope, model]
---
# ADR-004: Agent Scope

## Context
Only Claude Code is targeted today, but Codex, Gemini CLI and plain shells are plausible later. The session model is the part that is expensive to change.

## Decision
Claude Code only in milestone 1. The session model carries an `agent kind` field and `claude` is hardcoded in exactly one adapter type. Plain shell tabs work from day one because libghostty makes them free.

## Consequences
- An `AgentAdapter` protocol (launch command, resume command, state channel, transcript location) with a single `ClaudeCodeAdapter` implementation.
- No UI affordance for choosing an agent until a second adapter exists.
