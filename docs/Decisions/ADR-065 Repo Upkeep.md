---
status: accepted
date: 2026-09-07
tags: [adr, git, projects, milestone-4]
---
# ADR-065: Repo upkeep from the sidebar

## Context
Milestone 4 batch 4 ([[Collins Feature Gap]]): Git pull and Checkout main from the project header, Archive project, and trashing a session's worktree on archive with Undo.

## Decision
- **Project menu**: "Git Pull" (`git pull --ff-only`) and "Checkout <default branch>" (shown only while another branch is checked out). git's own stderr is shown in an error sheet on failure; the sidebar's branch label and the git page refresh afterwards.
- **Archive Project**: archives every visible session of the project and removes the project from the sidebar (reversible: Show Archived + Unarchive brings sessions back; the project reappears with them).
- **Worktree on archive**: when an archived session's last directory is a `<repo>/.claude/worktrees/<name>` worktree that no open tab or detached agent is using, ask **Keep Worktree / Trash Worktree / Cancel**. Trashing runs `git worktree remove --force` after moving the directory to the Trash with `FileManager.trashItem`, so uncommitted work is recoverable; the branch stays. "Undo Archive" restores the session and, when the Trash item still exists, moves the directory back and re-registers the worktree with `git worktree add <path> <branch>`. Preference: Ask (default) / Always trash / Never trash.
- Never touches `~/.claude` ([[ADR-018 Claude Data Write Policy]]).

## Consequences
- `GitRepository` gains `pull()`, `checkout(_:)`, `worktrees()`, `removeWorktree(_:)`, `addWorktree(path:branch:)`.
