---
status: superseded by ADR-079
date: 2026-09-07
tags: [adr, ui, terminal, milestone-2]
---
# ADR-046: Terminal panel

## Context
Collins offers a per-session dock of extra shells with tabs, splits, side rotation and persisted scrollback. Milestone 2 ([[Backlog]]) needs the everyday case: a shell next to the agent without leaving the tab.

## Decision
- ⌘J toggles one plain shell **below** the session's terminal, in a `VSplitView` with a draggable divider.
- The panel surface is owned by the `Tab`, created lazily in the tab's current directory, occluded with the tab, and freed with it. When its shell exits the panel closes.
- Panel `pwd`/title reports never touch the tab's footer or title; only the agent surface does.
- Deferred: multiple panel tabs, splits, right-side placement, persisted scrollback, panel layout persistence.

## Superseded
The shell is now a pane in the right-hand panel's tab strip, not a split below the agent surface — see [[ADR-079 Panel Tabs]]. Everything else here (one lazy surface per tab, owned by the tab, closing with its shell, never touching the tab's title or footer) still holds.

## Consequences
- One extra libghostty surface per tab at most; no layout tree to persist.
- If tabs or splits are wanted later, the panel becomes a strip container and this ADR is superseded.
