---
tags: [architecture, hooks]
---
# Hook protocol

Decisions: [[ADR-015 Hook Transport]], [[ADR-166 Session State Has More Than One Witness]], [[ADR-167 The Hook Socket Is Not Taken From A Live Instance]], [[ADR-017 Session Identity]], [[ADR-026 Session State Machine]], [[ADR-027 Installed Hook Set]]. Facts: [[Claude Code Hooks and Transcripts]].

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
{"type":"command","command":"'/Applications/Clinic.app/Contents/MacOS/clinic-hook' '<socket>'","async":true,"timeout":15}
```
`clinic-hook` reads stdin to EOF, appends `\n`, connects to the Unix socket (retrying for up to six seconds, ADR-167), writes the payload, `shutdown(SHUT_WR)`, exits 0. It never fails the CLI. If the socket is unreachable and `CLINIC_HOOK_TRACE_DIR` is set it appends to `<dir>/<session_id>.jsonl` instead.

`HookServer` (ClinicCore): `socket/bind/listen` at mode 0600, non-blocking accept via `DispatchSourceRead`, one payload per connection (read to EOF, 4 MiB cap, 1 s receive timeout, backlog 256). It never unlinks a socket a live instance answers on: a second Clinic uses `hook-<pid>.sock` and its own settings files, and the server re-binds its path if it disappears (ADR-167), decoded with `HookEvent.decode` (unknown fields ignored) and yielded on an `AsyncStream<HookEvent>`. `HookService` (app) pumps the stream to `TabStore.handle(hookEvent:)` on the main actor.

## Payload fields used
`reason`, `agent_id`, `hook_event_name`, `session_id`, `transcript_path`, `cwd`, `source`, `notification_type`, `message`, `tool_name`, `permission_mode`, `stop_hook_active`.

## State transitions
See `SessionStateMachine.reduce` — table in [[ADR-026 Session State Machine]]. `SessionStart` and `Stop` also trigger a targeted transcript re-read so titles update quickly.

## Witnesses (ADR-166)
Hooks name the state. Three other inputs may correct it, all through `TerminalWitness` (ClinicCore) and `TabStore.transition`:
- **OSC 9;4** (`GhosttyAction.progressReport`): `remove` ends `working`/`waitingForPermission` after 3 s; a busy report starts a turn from the prompt after 1.5 s. Only from a terminal that has reported busy. The settings file forces `terminalProgressBarEnabled`.
- **Title** (`GhosttyAction.setTitle` on a session tab): a spinner glyph ends `waitingForPermission`.
- **Transcript** (`SessionActivity.lastTurnEnd` via `SessionActivityStore.onChange`): a `turn_duration` or interrupt record later than the state began ends it.

`/clear`: `SessionEnd(reason: clear)` stamps the tab, `SessionStart(source: clear)` re-keys it to the new id; `tab(routing:)` still answers to the old one for the MCP shim.
