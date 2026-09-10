---
status: accepted (sidebar scope superseded by ADR-048)
date: 2026-09-07
tags: [adr, architecture, sessions]
---
# ADR-029: Discovery and Scanning

## Decision
On launch scan `~/.claude/projects/*/*.jsonl` (honouring `CLAUDE_CONFIG_DIR`). Per transcript read a bounded head (256 KB: first cwd, first user prompt, first timestamp) and a bounded tail (64 KB: latest `ai-title`, `custom-title`, last cwd, `cost-state`). Cache by (path, mtime, size). Watch the projects tree (DispatchSource/FSEvents, debounced) and rescan only changed files. Scanning runs in an actor off the main thread.

## Consequences
- The JSONL reader ignores unknown record types and decodes every field optionally.
- Cache lives in a separate file from state ([[ADR-021 Persistence]]).
