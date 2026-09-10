---
status: accepted
date: 2026-09-07
tags: [adr, ui, transcripts, milestone-3]
---
# ADR-059: Replay and session details

## Context
Collins offers **Replay** (a past transcript as chat bubbles, step-through or play) and **Details** (message/tool counts, models, tokens, timestamps, size, recent-activity peek, MCP servers) so a session can be understood without resuming it. Both read only the transcript. Real transcripts hold `user` records (string content, or `tool_result` blocks), `assistant` records with `text`/`thinking`/`tool_use` blocks and `message.usage` token counts, plus `cost-state`.

## Decision
- **`TranscriptTurns`** (ClinicCore): full-file reader producing `[Turn]` — `.user(text)`, `.assistant(text)`, `.toolUse(name, summary)`, `.toolResult(summary, isError)` — with thinking blocks counted, not shown; system-injected user text (`<system-reminder>`, `<local-command…>`) folded away; tool inputs summarised per tool (Bash → command, Read/Write/Edit → path, others → first string field). Also `TranscriptStats`: user/assistant message counts, tool calls by name, models used, input/output/cache tokens summed from `usage`, cost from `cost-state`, first/last timestamps, duration, transcript size, MCP server names seen in tool names (`mcp__<server>__<tool>`).
- **Replay** (⌘⇧R… no: ⌘⌥R; context menu "Replay…"): opens as its own **tab** (kind `.replay(sessionId)`, no surface) in the content area: a scrolling list of bubbles (user right-aligned accent, assistant left, tool calls as compact monospaced rows, results collapsed behind a disclosure), a footer with **Step** (reveal next turn), **Play** (reveal one turn every 0.7 s), **Show all**, and a turn counter. Read-only.
- **Details** (context menu "Details…", ⌘I): a sheet with the stats grid, models, tool-call table, MCP servers, the last three user/assistant turns as a peek, and buttons for Reveal Transcript and Copy ID.
- Files over 50 MB are refused with a message; parsing runs off the main actor.

## Consequences
- `Tab.Kind` gains `.replay(SessionID)`; such tabs have no surface and are skipped by libghostty-related code paths.
- Replay/detail parsing is on demand, never part of the sidebar scan.
