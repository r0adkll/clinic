---
tags: [architecture, hooks]
---
# Hook protocol

Decisions: [[ADR-015 Hook Transport]], [[ADR-017 Session Identity]], [[ADR-026 Session State Machine]], [[ADR-027 Installed Hook Set]]. Facts: [[Claude Code Hooks and Transcripts]].

## Launch
Every Clinic-launched session is typed into the user's login shell via libghostty `initial_input` ([[ADR-016 Launch Shape]]):
```
claude --session-id <uuid> [--model X] [-w] --settings '~/Library/Application Support/Clinic/hooks.json'
claude --resume <uuid> [--fork-session] --settings '…/hooks.json'
```
`ClaudeLaunch` (ClinicCore) builds and shell-quotes the line. `HookSettings.json` writes `hooks.json` once per app launch with the absolute helper path from `Bundle.main`.

## Transport
`hooks.json` registers, for each event in ADR-027:
```json
{"type":"command","command":"'/Applications/Clinic.app/Contents/MacOS/clinic-hook' '<socket>'","async":true,"timeout":5}
```
`clinic-hook` reads stdin to EOF, appends `\n`, connects to the Unix socket, writes the payload, `shutdown(SHUT_WR)`, exits 0. It never fails the CLI. If the socket is unreachable and `CLINIC_HOOK_TRACE_DIR` is set it appends to `<dir>/<session_id>.jsonl` instead.

`HookServer` (ClinicCore): `socket/bind/listen` at mode 0600, non-blocking accept via `DispatchSourceRead`, one payload per connection (read to EOF, 4 MiB cap, 5 s receive timeout), decoded with `HookEvent.decode` (unknown fields ignored) and yielded on an `AsyncStream<HookEvent>`. `HookService` (app) pumps the stream to `TabStore.handle(hookEvent:)` on the main actor.

## Payload fields used
`hook_event_name`, `session_id`, `transcript_path`, `cwd`, `source`, `notification_type`, `message`, `tool_name`, `permission_mode`, `stop_hook_active`.

## State transitions
See `SessionStateMachine.reduce` — table in [[ADR-026 Session State Machine]]. `SessionStart` and `Stop` also trigger a targeted transcript re-read so titles update quickly.
