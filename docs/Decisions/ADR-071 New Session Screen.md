---
status: accepted
date: 2026-09-07
supersedes: part of ADR-055, ADR-032
tags: [adr, ui, sessions]
---
# ADR-071: New session screen in the content area

## Context
[[ADR-055 No Prompt Composer]] removed both the docked composer and the first-prompt screen. User (2026-09-07): the docked composer stays out, but starting a session should be a screen in the main content area, not a sheet — type the first prompt, pick model and effort, set worktree and branch preferences, then Send.

## Decision
- "New Session" (⌘N, toolbar, project header click and "+", Chats header) opens a **screen in the content area** for the project in view: project header, prompt editor (⌘↩ sends), **model** picker (default/sonnet/opus/haiku/custom), **effort** picker (CLI default plus low…max), **New git worktree** toggle with an optional **branch name** (passed as `claude -w <name>`; the CLI names the worktree and branch after it). **Send** launches with the prompt as the first turn; **Empty Session** launches without one.
- Per-project defaults for model, effort and worktree are remembered; unsent text is kept in memory per project while the app runs (no persisted draft rows).
- With no project in view, "New Session in Folder…" (⌘⇧N) picks a folder first, then opens the screen.
- The docked composer for running sessions stays removed.

## Consequences
- `ClaudeLaunch.worktreeName` → `-w <name>`; `TabStore.editingDraft` drives `DetailView`.
- The New Session sheet is reduced to the folder picker.
