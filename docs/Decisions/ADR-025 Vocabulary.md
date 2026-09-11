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
- **Task** (UI) / **work item** (code): an issue or ticket from a tracker (GitHub, later GitLab and others). *Amended 2026-09-10 by [[ADR-113 Work Item Providers and Sources]].*
  - The UI says "Tasks".
  - Code says `WorkItem`, `WorkItemRef`, `WorkItemSource` and `WorkItemProvider`, never `Task`, which is Swift's concurrency type.
  - A work item is not one of Claude Code's own todo items, and not a background agent ([[ADR-061 Background Agents]]).

Never 'workspace' or 'thread'.

## Consequences
- Type names: `Project`, `Session`, `Surface`, `Tab`, `WorkItem`. Stores are `ProjectStore`, `SessionStore`, `TabStore` and `TasksStore`.
