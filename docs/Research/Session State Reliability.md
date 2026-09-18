---
tags: [research, hooks, sessions, prior-art]
date: 2026-09-18
sources: [https://github.com/stablyai/orca, https://github.com/episode6/collins, https://code.claude.com/docs/en/hooks]
---
# Session state reliability — why `working` sticks, and what others do

User (2026-09-18): the hooks "kinda disconnect" and sessions stay `working` while visibly idle.
Built the same day as [[ADR-166 Session State Has More Than One Witness]] and [[ADR-167 The Hook Socket Is Not Taken From A Live Instance]]; the measured hook, OSC and title timeline is the table in ADR-166. Decisions affected: [[ADR-015 Hook Transport]],
[[ADR-026 Session State Machine]], [[ADR-027 Installed Hook Set]].

## The structural problem
Hooks are Clinic's **only** state source ([[ADR-026 Session State Machine]] demotes OSC 9;4 to "corroborating, never a
source", and `TabStore` drops `.progressReport`). Delivery is fire-and-forget: async hook, one connect, no retry,
no spool, no acknowledgement. One lost or never-sent `Stop` leaves `working` with nothing to correct it.

## Failure modes found in Clinic (read from source, not reproduced)
1. **Interrupt fires no hook.** Docs: Stop "does not run if the stoppage occurred due to a user interrupt". Clinic
   waits for `idle_prompt` (~60 s, only if nothing is typed) and then lands on `waitingForInput`, not `idle`.
2. **A second Clinic instance steals the socket.** `HookServer.start` unlinks and rebinds `hook.sock`; `stop` unlinks
   it. A Debug build beside the installed app, or a smoke run without `CLINIC_APP_SUPPORT`, cuts the live app off
   until relaunch. It happened on 2026-09-08. The live server never notices.
3. **Hooks for an unknown `session_id` are dropped** (`TabStore.handle`, debug log only). Adoption happens only for a
   tab with `awaitingId`. `/clear` sends `SessionEnd(reason: clear)`, which the reducer maps to `exited`, then
   `SessionStart(source: clear)`. **Verified 2026-09-18 on 2.1.276: `/clear` does change the id**, so every later hook was dropped.
4. **Manual `/compact` ends at the prompt without `Stop`** (orca #11352). Clinic does not register `PostCompact`.
5. **No retry in `clinic-hook`.** A refused connect (backlog of 64 full, or the socket gone) loses the event. The
   trace-file fallback needs `CLINIC_HOOK_TRACE_DIR`, which a launched session never has.
6. **`HookServer` reads on the same serial queue as accept**, blocking, 5 s receive timeout. One stalled helper delays
   every session's events. The status line multiplies connection volume on that queue.
7. **The reverse case:** a turn woken by a background task or wake-up may start without `UserPromptSubmit`, so a working
   session shows `idle`. **Checked and not real**: a background task waking the model does fire `UserPromptSubmit`. What is real is that `PreToolUse` arrives *before* `PermissionRequest`, so an approved permission stayed orange until the next tool call.
8. **Subagents:** events carrying `agent_id` are not distinguished from the lead's.

## orca (stablyai/orca, HEAD 209d2d8)
- Hooks are the authority, **synchronous**, `curl` to a localhost port, 0.5 s connect / 1.5 s total.
- Endpoint is re-read from a pointer file on **every hook run**, so panes survive an app restart.
- Failed delivery **spools** to `spool/pane-<id>.jsonl` (tool events skipped, 5 MB / 7 days) and is replayed at start.
- Clearing events beyond Stop: StopFailure, SessionStart (startup/resume/clear), manual PostCompact, SessionEnd.
- `agent_id` events never become the lead's state; Stop is held while `background_tasks` / `session_crons` are live.
- Interrupt: inferred from Ctrl+C (not bare Esc), applied after 500 ms only if the row is unchanged; a late
  `working` within 15 s is suppressed.
- Fallback: terminal title (`✳` idle, spinner glyphs working). Decay: 30 min. Restored rows are `unconfirmed`.
- Its open stuck-working bugs (#10114, #11352, #21327) all come from refusing to let an idle title overrule a
  working hook. **Lesson: a second signal must be allowed to demote `working`.**

## Collins (no hooks at all)
- Primary: **OSC 9;4**. Busy marks working with a 60 s safety window. A clear becomes idle only after a 3 s grace
  (the CLI blips between tool calls) and only if that tab has emitted busy before.
- Fallbacks: redraw activity behind an echo gate, spinner motion, process tree, `claude agents --json`.
- **Transcript as witness**: a finish counts only if the transcript advanced (`turn_duration` record or a new
  assistant line). Interrupted = last meaningful record contains `[Request interrupted by user`.
- Every mark has a deadline.

## Claude Code facts
- `terminalProgressBarEnabled` is on by default and emits the in-progress state for Ghostty ≥ 1.2.0. It stays on
  while background subagents run and clears once the session is idle. Clinic's surfaces report `TERM_PROGRAM=ghostty`, version 1.3.1, and the CLI emits it there (verified). The setting is honoured from `--settings`.
- `idle_prompt` and `permission_prompt` lag by ~60 s and ~6 s and need the user to be away.
- Async hooks have no delivery guarantee. SessionEnd hooks share a 1.5 s budget.
- The status line has no busy/idle field.

## Options, ranked
1. Let OSC 9;4 demote `working` (Collins's grace rules). Supersedes the "never a state source" line of ADR-026.
2. Transcript witness in the existing `TranscriptFollower`: `turn_duration` ends a turn, the interrupt marker ends it.
3. Transport: retry the connect, spool on failure and replay, concurrent reads, notice a stolen socket, refuse to
   steal a live one.
4. Reducer: register `PostCompact`; treat `SessionEnd(reason: clear)` as a re-key, not an exit; key by tab;
   honour `agent_id`; `PreToolUse` while `idle` means `working`.
5. A deadline on `working` with no evidence from any source.
6. Diagnostics: count dropped and unknown-session events at `info`, not `debug`.
