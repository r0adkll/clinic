---
status: accepted
date: 2026-09-07
tags: [adr, ui, sessions, milestone-4]
---
# ADR-064: Model and effort switching from the footer

## Context
Milestone 4 batch 3. Collins turns the footer's model and effort chips into menus that send the CLI's `/model <id>` and `/effort <level>` commands and follow the transcript's confirmation. Claude Code fires `PostModelSwitch` and writes the model into assistant records; effort levels are `low, medium, high, xhigh, max`.

## Decision
- The footer model chip is a menu: Default, Sonnet, Opus, Haiku, Custom… (asks for an id), plus Copy model id. Picking one types `/model <alias>` into the session, only when it is idle at its prompt; otherwise the menu items are disabled with a tooltip. The footer updates when the `PostModelSwitch` hook or the next transcript re-read reports the new model.
- An effort chip beside it (Default plus the five levels) sends `/effort <level>` the same way. The chosen level is remembered per session in memory only; the transcript's `effort` field, when present, wins.
- Not now: the Models API catalogue (needs the OAuth token), greying levels a model cannot take.

## Consequences
- Observed: the CLI answers `/model` with "Set model to … and saved as your default for new sessions", so a footer switch also changes the CLI's default; `PostModelSwitch` carries no model name (only `source: command`), so the chip shows the alias sent until the transcript reports the resolved model.
- `TabStore.sendSlashCommand(_:to:)` is the one path for typed commands, reused by the PR page's send-to-session.
