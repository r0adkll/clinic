---
status: accepted (built 2026-09-18)
date: 2026-09-18
supersedes: "the last line of [[ADR-026 Session State Machine]] (\"`PROGRESS_REPORT` is a corroborating signal only, never a state source\"), and its `SessionEnd` → `exited` and `SessionStart` → `idle` rows where the reason is `clear` or the source is `compact`"
amends: "[[ADR-027 Installed Hook Set]] (the settings file also sets `terminalProgressBarEnabled`)"
tags: [adr, architecture, sessions, hooks]
---
# ADR-166: Session state has more than one witness

## Context
User (2026-09-18): *"our status line hooks kinda disconnect and sometimes the session stay in a 'working' state
even though they appear idle."*

[[ADR-026 Session State Machine]] made hooks the only source of state. A hook is a helper process per event,
sent once, and some endings send none. Nothing else was allowed to correct what that left behind. Research
and the prior art are in [[Session State Reliability]].

Measured against the real CLI (2.1.276) on 2026-09-18, in a pty with every hook forwarded to a logging socket:

| what happened | hooks | OSC 9;4 | title |
|---|---|---|---|
| prompt submitted | `UserPromptSubmit` | `4;3` once | `◐`/`◑` alternating |
| turn ended | `Stop` | `4;0` once, 10 ms later | `✳` |
| **Esc mid-turn** | **none** | `4;0` within 60 ms | `✳` |
| permission dialog up | `PreToolUse`, *then* `PermissionRequest` | stays `4;3` | `✳` |
| **Esc at the dialog** | **none** | `4;0` | `✳` |
| `/clear` | `SessionEnd(reason: clear)`, then `SessionStart(source: clear)` **with a new `session_id`** | none | `✳` |
| manual `/compact` | `PreCompact`, `SessionStart(source: compact)`, `PostCompact`. No prompt, no `Stop` | `4;3` … `4;0` | |
| background task wakes the model | `UserPromptSubmit` … `Stop` | `4;3` … `4;0` | |
| `/exit` | `SessionEnd` | `4;3` for 250 ms, then `4;0` | |
| `terminalProgressBarEnabled: false` in `--settings` | unchanged | one `4;0` at start and exit, never `4;3` | |

So four things were wrong, and only the first is about delivery:
1. **An interrupt left `working` for a minute**, until `idle_prompt`, and then landed on `waitingForInput`. A
   dialog dismissed with Esc left `waitingForPermission` the same way.
2. **`/clear` disconnected the tab for good.** `SessionEnd` marked it `exited`; every later hook carried an id no
   tab had and was dropped at `debug`, which the log does not keep.
3. **An approved permission stayed orange.** `PreToolUse` arrives *before* `PermissionRequest`, so the event ADR-026
   expected to end the wait had already gone by. The state held until the next tool call or `Stop`, which for
   a long build is minutes.
4. **An automatic compaction showed `idle` mid-turn**, because any `SessionStart` meant `idle`.

## Options
- **Timed decay** (orca: 30 minutes). Rejected: a long tool run is legitimately silent, so any deadline short
  enough to help is wrong for a build.
- **Infer the interrupt from the keystroke** (orca). Rejected: Esc also closes overlays, and the CLI says
  what happened itself 60 ms later.
- **Screen scraping** (Collins). Rejected; nothing here needs it.
- **Let the terminal and the transcript correct the hooks.** Chosen.

## Decision
Hooks stay the first witness and the only one that *names* a state. Two others may correct it.
`TerminalWitness` (ClinicCore) holds the rules as pure functions; `TabStore` holds the timers.

### OSC 9;4, the second witness
- **A quiet report ends a turn.** `remove` while `working` or `waitingForPermission` moves the tab to `idle`
  after **3 s**, unless a hook or a busy report arrives first. `Stop` normally lands in milliseconds and wins,
  so the grace is only ever waited out when a hook is missing. It goes through the same transition as `Stop`,
  so an unwatched tab still gets *Finished* and its unread dot.
- **Only from a terminal that has said busy.** With the setting off the CLI sends `remove` at startup and exit
  and nothing else. A tab that has never reported busy is never ended by a quiet report.
- **A busy report starts a turn**, after **1.5 s**, when the tab is at its prompt (`idle`, or `waitingForInput`
  on `idle_prompt`). That covers a lost `UserPromptSubmit`. The grace is there because `/exit` sets the report
  for a quarter of a second, and a turn that short should not raise *Finished*.
- **`HookSettings.json` sets `terminalProgressBarEnabled: true`**, verified to be honoured from `--settings`.
  Clinic draws no progress bar, so a user who turned it off for their own terminal loses nothing.
- `pause` and `error` are not the CLI's and are ignored. Panel terminals and shell tabs are ignored.

### The title, for the one thing nothing else says
A title whose first glyph is a spinner (`◐◑◒◓`, or braille before 2.1.228) while the tab is
`waitingForPermission` moves it to `working`. The CLI's own rule for animating the title is "loading and not
blocked on a dialog", which is exactly the question. The title is used for nothing else: `✳` means *resting or
blocked*, so it cannot end a turn.

### The transcript, the third
`SessionActivity.lastTurnEnd` is the timestamp of the last main-chain `turn_duration` record or
`[Request interrupted by user…` user record. When it is more than half a second later than the moment the tab
entered `working` or `waitingForPermission`, the tab goes `idle`. The margin keeps the previous turn's closing
record from ending a turn that a queued prompt started in the same few milliseconds. This is the witness that
still works when OSC 9;4 does not, and it costs nothing: `TranscriptFollower` already reads every line.
A Ctrl-C mid-stream writes no marker, which is why it is third and not second.

### `/clear` re-keys the tab
- `SessionEnd` with `reason: clear` changes no state and stamps the tab.
- The `SessionStart(source: clear)` that follows re-keys the stamped tab to the new id, registers the new
  session as owned, and rewrites `lastResume` and the MCP config. If the `SessionEnd` was lost, the only live
  session tab in the reported `cwd` is taken instead.
- The tab follows the process. The transcript it left stays in the sidebar as a session of its own, as a fork's
  parent does.
- The MCP shim was launched with the first id and keeps sending it, so `tab(routing:)` also matches a tab's
  former ids, and a tool call is attributed to the tab's current one.

### The reducer
`SessionStart` with `source: compact` and `SessionEnd` with `reason: clear` change nothing. `HookEvent` decodes
`reason` and `agent_id`.

### Dropped hooks are logged
A hook for a session no tab has is logged at `notice`, and so is every correction a witness makes
("terminal progress moved … from working to idle; no hook did"). The next report of a stuck session can be
read out of `/usr/bin/log show`.

## Consequences
- Verified in the app, not only in tests: a smoke instance started a session through the new
  `-ClinicSessionOnLaunch`/`-ClinicSessionPrompt`/`-ClinicSessionModel` seam and sent it Ctrl-C after 12 s
  (`-ClinicInterruptAfter`). The hook trace holds `SessionStart` and `UserPromptSubmit` and nothing after; the
  log shows the tab moved to `idle` 3 s after the interrupt.
- **Not driven in the app:** `/clear`, the permission title, and the transcript witness. Their rules are
  covered by `SessionWitnessTests` against the recorded sequences above, and the wiring by the build.
- `PreToolUse` from an idle tab still starts nothing. Hooks race each other as processes, so a late one after
  `Stop` would strand `working` with no quiet report left to end it.
- Subagent events are still not told apart from the lead's. A background subagent that asks permission after
  the lead's `Stop` moves the tab to `working`; the CLI keeps the report set while subagents run and clears it
  when they finish, which now ends it.
- An attached session (`claude attach`) has no state, as before.
