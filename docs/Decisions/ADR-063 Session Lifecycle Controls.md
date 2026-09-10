---
status: accepted
date: 2026-09-07
tags: [adr, sessions, ui, milestone-4]
---
# ADR-063: Session lifecycle controls

## Context
Milestone 4 batch 2 ([[Collins Feature Gap]]): graceful stop, close that exits cleanly first, fork, continue-last, open in Ghostty, Open In…, export Markdown.

## Decision
- **Stop** (Session menu ⌘., hover, context menu): sends Ctrl‑C twice to the agent surface (Claude Code's clean exit), leaving the shell in the tab; the `SessionEnd` hook moves the row to exited and the Resume button appears.
- **Close** with a running session: the sheet's Close now stops gracefully first and closes the tab when `SessionEnd` arrives (5 s fallback), instead of killing the shell. Background stays as the alternative ([[ADR-061 Background Agents]]).
- **Fork**: `claude --resume <id> --fork-session` in a new tab. The fork's id is only known when `SessionStart(source: fork)` arrives, so `Tab.kind` becomes mutable and the tab rebinds to the new id, which is registered as owned.
- **Continue last session** (project menu): `claude --continue` in the project directory; same rebinding on `SessionStart`.
- **Open in Ghostty** (context menu, when Ghostty.app is installed): launches Ghostty with the resume command and Clinic's hooks file in the session's directory, without a Clinic tab.
- **Open In…** submenu on project headers and session rows: Finder, Ghostty, and any of Xcode, VS Code, Cursor, Zed, IntelliJ, Android Studio that are installed.
- **Export as Markdown…** (context menu): turns → Markdown via `TranscriptTurns.markdown`, saved through a save panel.

## Consequences
- `ClaudeLaunch.Mode` gains `.continueLast`; hook handling gains rebinding for tabs awaiting an id.
- Nothing writes under `~/.claude` ([[ADR-018 Claude Data Write Policy]]).
