---
status: accepted
date: 2026-09-07
tags: [adr, naming]
---
# ADR-025: Vocabulary

## Decision
- **Project**: a directory group, matching one encoded cwd (worktrees fold into their repo's project).
- **Session**: one Claude Code conversation, one transcript, one id.
- **Surface**: one libghostty terminal.
- **Tab**: an open Session or shell inside the window.
Never 'workspace' or 'thread'.

## Consequences
- Type names: `Project`, `Session`, `Surface`, `Tab`; stores are `ProjectStore`, `SessionStore`, `TabStore`.
