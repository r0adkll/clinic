---
status: accepted (sidebar scope superseded by ADR-048)
date: 2026-09-07
tags: [adr, scope, milestones]
---
# ADR-013: Milestone 1 Slice

## Context
Collins is the spec ([[ADR-002 Collins as the Milestone 1 Spec]]) but milestone 1 must be a thin vertical slice usable daily. Candidates ranged from the sidebar and terminal to git, PR, editor and composer pages.

## Decision
Milestone 1 contains:
- **A** Sidebar of projects and sessions read from the JSONL store: names, relative time, status.
- **B** Open or resume a session in a libghostty surface.
- **C** New session with model choice and optional worktree.
- **D** Live per-session state from hooks: working, waiting for you, idle, exited.
- **E** Unread marker, system notification and dock badge when a session finishes or needs input.
- **I** Plain shell tabs.

Deferred to milestone 2: rename, favorite, archive (F); search and quick switcher (G); footer with cwd/branch/model (H); terminal panel and splits; notification history; multiple windows.
Milestone 3+ (one each): git page, PR page, editor, composer, attachments, session MCP tools, usage panel, replay, export, background agents, project icons, i18n, Sparkle.

## Consequences
- The loop to prove is: see all sessions → open one → know when it wants me.
- [[Backlog]] is organised by these milestones.
