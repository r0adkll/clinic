---
status: superseded by ADR-055
date: 2026-09-07
tags: [adr, ui, composer, milestone-3]
---
# ADR-054: Prompt composer, new-chat screen and drafts

## Context
Third page of milestone 3. Collins: a multi-line composer floating over the terminal (⌘.), a new-chat screen where the first prompt is written with model/effort/worktree pickers, unsent screens kept as Draft rows, image/file drop. Verified: libghostty's `text:` binding action writes raw bytes to the pty (with `\x1b` escapes), so a bracketed paste (`ESC[200~ … ESC[201~`) delivers multi-line text to Claude Code's input box; the CLI accepts the first prompt as a positional argument and `--effort low|medium|high|xhigh|max`.

## Decision
- **Composer** (⌘.): a panel docked under the session's terminal with a multi-line editor. Return sends, Shift+Return inserts a newline. Send = bracketed paste via `GhosttySurfaceView.sendPaste` followed by Return, enabled only when the session is idle at its prompt (otherwise the button explains why). Text is kept per session as a draft (`ClinicState.sessionDrafts`) and restored when the tab reopens.
- **Drop**: files dropped on the composer insert their paths; images are copied to `~/Library/Application Support/Clinic/dropped/` first so a pasted screenshot has a stable path Claude can read.
- **New-chat screen**: ⌘N with a project in view opens a screen in the content area: project header, prompt editor, worktree toggle, model picker, effort picker (`low…max`, default "CLI default"). **Send** launches `claude --session-id … [--model] [--effort] [-w] "<prompt>"`; **Empty Session** launches without a prompt. With no project in view, the folder picker sheet runs first.
- **Drafts**: an unsent new-chat screen with text is a `NewChatDraft` (project, prompt, model, effort, worktree) persisted in state and listed as a "Draft" row (pencil glyph) under its project; opening it restores the screen; Send spends it; a trash button discards it.
- **Not now**: spell-check toggle, floating (undocked) mode, typing-trigger that opens the composer when you start typing, model/effort menus inside the composer chrome for a running session (milestone 4).

## Consequences
- The composer never types while Claude is working; the state machine ([[ADR-026 Session State Machine]]) gates it.
- `ClaudeLaunch` gains `prompt` and `effort`.
- The new-chat screen is content-area UI without a surface; the tab and surface are created on Send.
