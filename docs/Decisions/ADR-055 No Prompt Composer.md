---
status: accepted (new-session screen restored by ADR-071; composer stays removed)
date: 2026-09-07
supersedes: ADR-054
tags: [adr, ui, scope]
---
# ADR-055: No prompt composer or new-chat screen

## Context
[[ADR-054 Prompt Composer and Drafts]] shipped a docked composer and a first-prompt screen with drafts, mirroring Collins. The user's reaction on first use: the embedded terminal already runs Claude Code's own input box, so a second prompt editor is redundant.

## Decision
Remove the composer, the new-chat screen and draft rows. New Session is the compact sheet (project, model, effort, worktree) and launches straight into the terminal; the first prompt is typed to Claude directly. Keep `GhosttySurfaceView.sendPaste` and `ClaudeLaunch.prompt` in the lower layers: the session MCP tools and the PR page's "send to session" deliver text through them.

## Consequences
- Image/file drop onto the terminal is not provided by Clinic; Claude Code's own paste handling applies.
- Collins's typing-trigger, floating composer and draft rows are permanently out of scope.
- Milestone 3 continues with attachments and MCP tools.
