---
status: superseded
superseded-by: "[[ADR-080 Diff Panel]]"
date: 2026-09-07
tags: [adr, git, ui, milestone-3]
---
# ADR-052: Git page

> Superseded by [[ADR-080 Diff Panel]] (2026-09-08): the pane is now a read-only multi-scope
> diff reader. The `GitRepository` actor, the `UnifiedDiff` parser and the FSEvents reload survive;
> the status/stage/commit UI and the list-then-detail layout do not.

## Context
First page of milestone 3 ([[Backlog]]). Collins's git page: per-file cards, per-hunk views, split/stacked, word emphasis, image before/after, commit list down to trunk, unstaged/staged lists, stage/unstage/discard/revert at file/hunk/line via `git apply`, commit + fixup, notes on hunks, vim keys, auto-reload. Clinic needs the core loop first, with a diff view that the PR page and the agent's `show_diff` tool can reuse.

## Decision
- **Where**: a column to the right of the terminal inside the session tab (`HSplitView`), toggled by ⌘⇧G, a footer button, and clicking the footer branch. Per-tab open state; the repo is discovered from the tab's cwd (worktree-aware, so a `-w` session shows its worktree).
- **What**: branch header with ahead/behind; **Changes** list split into Unstaged (incl. untracked) and Staged, each row with status glyph and Stage/Unstage; **Diff** of the selected file, unified, hunks with Stage/Unstage (and Discard for unstaged, confirmed) per hunk, line numbers, monospaced, horizontal scroll; **Commit** box (message, Commit, Amend); **Commits** list (`base..HEAD` where base is the default branch, else recent commits) — click a commit to view its diff (read-only).
- **How**: `GitRepository` actor in ClinicCore wraps the `git` CLI (porcelain v2 status, unified diff, `git apply --cached` for hunks and line selections). `UnifiedDiff` parser + patch reconstruction is the reusable piece. `FSEventsWatcher` on the repo root (ignoring `.git/objects`) triggers a debounced reload.
- **Not now**: split view, word-level emphasis, image diffs, notes/highlights (arrive with MCP tools), vim keys, line-level staging UI (core supports it; UI later), fixup commits.

## Consequences
- The diff view (`DiffView`) is a standalone SwiftUI component taking a `UnifiedDiffFile` and optional action callbacks; the PR page reuses it read-only.
- Destructive operations (discard) always confirm; no `git push`/`pull` here (repo upkeep is milestone 4).
