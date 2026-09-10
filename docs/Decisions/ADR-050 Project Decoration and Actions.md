---
status: accepted
date: 2026-09-07
tags: [adr, ui, projects]
---
# ADR-050: Project decoration and inline actions

## Context
Collins project headers carry an icon, uppercase name, count pill, a "+" button and a menu; session rows reveal actions on hover. Clinic's headers were bare text.

## Decision
- **Project header**: icon + name + count + "+" (new session here). Icon resolution: `<project>/project-icon.svg|png` → `<project>/.clinic/icon.*` → a monogram (first letter) on a colour derived from a hash of the path. ~~No headless icon generation.~~ (generation added by [[ADR-076 Project Icon Generation]])
- **Project menu** (header ⋯ and context menu): New Session…, New Session in Worktree, Import Session…, Open in Finder, Open in Terminal (shell tab), Open on GitHub (when a GitHub remote exists), Copy Path, Remove Project (hides the project; owned sessions are archived, nothing on disk changes).
- **Session row hover actions**: ~~replace the timestamp with~~ (moved to the trailing edge by [[ADR-077 Persistent Projects and Sidebar Polish]]) Close (when open), Archive, and Favorite buttons.

## Consequences
- Remote detection via `git remote get-url origin`, cached per project.
- Icons are loaded once per project and cached; `.clinic/` is Clinic's per-project namespace.
