---
status: accepted
date: 2026-09-07
tags: [adr, sessions, ui]
---
# ADR-030: Project Grouping

## Decision
Group by the cwd recorded inside the transcript, not the lossy encoded directory name. A cwd under `<repo>/.claude/worktrees/<name>` folds into `<repo>`'s project. Projects remain visible when all sessions are archived. 'Add project' picks a folder with no sessions yet. Display name = last path component; full path as tooltip.

## Consequences
- Project identity = canonical absolute path.
