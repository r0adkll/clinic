---
status: accepted
date: 2026-09-07
tags: [adr, sessions, background, milestone-3]
---
# ADR-061: Background agents

## Context
Claude Code can run sessions detached: `claude --bg "prompt"` starts one and prints an id; `/bg` inside a session detaches it; `claude agents --json [--all]` lists sessions (`id`, `sessionId`, `kind` interactive|background_agent, `status` busy|idle…, `state` working|needs_input|idle|completed|failed, `waitingFor`, `cwd`, `name`, `pid`, `startedAt`); `claude attach <id>` reopens one in a terminal (← returns to agent view, Ctrl+Z drops to the shell); `claude logs|stop|rm|respawn <id>` manage it. The CLI refuses `--resume` for a session that is still running detached. Collins re-attaches instead of resuming, offers "background" in the close dialog and on hover, and polls `agents --json` while any detached session exists.

## Decision
- **Registry**: `BackgroundAgentsService` polls `claude agents --json --all` every 15 s while the app is active (and immediately after any launch/close/attach), parsing into `BackgroundAgent` values. Rows for `kind == background_agent` appear in the sidebar under their project (imported as owned if unknown) with a **detached** glyph and state from `state`/`waitingFor`.
- **Attach instead of resume**: opening a session whose id is listed as a running background agent launches `claude attach <id>` in the tab; the tab's state comes from hooks as usual once attached.
- **Detach**: the close sheet gains **Background** (types `/bg` and closes the tab once the child exits) when the session is idle; a hover action and Session menu item do the same. Not offered before `SessionStart` has confirmed the id.
- **Actions** on detached rows: Attach, Stop (`claude stop`, confirmed), Logs (opens a shell tab running `claude logs <id>`), Remove (`claude rm`, confirmed; never deletes transcripts under `~/.claude`, which the CLI owns).
- **Notifications**: a detached agent reaching `needs_input`, `completed` or `failed` posts through the existing notification path (system notification + history), de-duplicated per transition.
- Not now: `claude --bg` from the New Session sheet (a session started attached can be backgrounded later), respawn, per-project cwd filtering.

## Consequences
- `ClaudeLaunch.Mode` gains `.attach(id)`.
- Polling stops when no detached agents exist and no tab is attached, so idle cost is one process spawn per 15 s only while something is detached.

## Correction (2026-09-09, from [[ADR-095 Automations]])

Two statements above are wrong about what the CLI actually does. Both were found by probing it
directly while designing Automations, and both are fixed in code; the decision itself stands.

- **`done` is the terminal state, not `completed`.** A background session that finishes reports
  `state: "done"` with `status: "idle"`, and its process stays **resident and attachable**. This ADR's
  `isRunning` treated only `completed`/`failed`/`stopped` as terminal, so every finished agent read as
  running: the sidebar kept its detached badge, the row action stayed *Attach*, *Stop Detached Session*
  stayed on the menu, [[ADR-065 Repo Upkeep]] thought the directory was in use, and this ADR's own
  "polling stops when no detached agents exist" never happened — the 15 s poll ran forever after the
  first detached session. The notification promise ("a detached agent reaching … `completed` … posts
  through the existing notification path") had the same hole and never fired on a normal finish.
  `BackgroundAgent.terminalStates` / `attentionStates` / `announcedStates` now hold these sets in one
  place so the two lists cannot drift apart again.
- **`claude rm` deletes the worktree and its branch**, not just job state — `claude stop` says so in
  its own output (`run 'claude rm <id>' to remove worktree and job state`). The claim here that it
  "never deletes transcripts under `~/.claude`" is true and is not the whole story: Remove is more
  destructive than this ADR implies, and its confirmation must say what goes with it.

Also worth recording, since this ADR is where anyone will look: **`claude logs <id>` returns a raw ANSI
TUI replay**, not readable text, so it is fit for a terminal pane and useless as a data source.
