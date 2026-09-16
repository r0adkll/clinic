---
status: accepted (built 2026-09-16; context size superseded by ADR-157, then drawn as a gauge by ADR-158)
date: 2026-09-16
amends: "[[ADR-077 Persistent Projects and Sidebar Polish]] (the session row becomes one of three styles), [[ADR-096 Session Status Indicators]] (a child that needs you raises the glyph)"
tags: [adr, ui, sidebar, sessions, transcript]
---
# ADR-156: Sessions can be cards

## Context
User (2026-09-16): *"Let's consider the current state/rendering of sessions in the sidebar the 'Compact'
from right now. Let's explore a design of a larger 'Card' format that displays more information about
the session as well as a sublist sub-agents spawned, run configurations that are in progress, PRs, and
any other live child process that would be worth surfacing."* After reviewing a published mockup
(Compact / Cards / Automatic, the card's zones, a table of child sources, open questions each with a
lean): *"This looks great, let's implement it"*. The leans were accepted as they stood.

The row of [[ADR-040 Sidebar Ordering and Row Visuals]] and [[ADR-077 Persistent Projects and Sidebar Polish]]
says whether a session wants you, not what it is doing. An agent that has three subagents out, a build
running in the background and a Grill round waiting reads exactly like one idling at the prompt.

Probed against real transcripts on this Mac (CLI 2.1.273) before deciding anything:
- **Every `Agent` tool call launches async.** Its result is `toolUseResult.status: "async_launched"`
  with an `agentId`, and the agent's own turns go to `<transcript>/subagents/agent-<id>.jsonl` beside a
  `.meta.json` (`agentType`, `description`, `toolUseId`, `spawnDepth`). An older synchronous agent's
  result carries `status: "completed"`.
- **`Bash` with `run_in_background`** returns `backgroundTaskId` and a text naming the output file
  (`/private/tmp/claude-<uid>/<cwd>/<session>/tasks/<id>.output`). **`Monitor`** returns `taskId`.
- **All three end with a `<task-notification>`** carrying `<task-id>`, `<tool-use-id>`, `<output-file>`
  and `<status>` (seen: `completed` 842, `failed` 112, `stopped` 6, `killed` 2). One event is written
  up to three times: a `queue-operation` record, a `queued_command` attachment, and a user record whose
  `origin.kind` is `task-notification`. A Monitor's ends with *"stream ended"*.
- A prompt the user typed has `origin.kind: "human"` (older records have no `origin`).
- A `system` record with subtype `away_summary` is the CLI's own one-paragraph recap of the session.
- An `attachment` of type `model` names the model: `identity.marketingName` ("Opus 5").
- The binary has `SubagentStart` / `SubagentStop` / `TaskCreated` / `TaskCompleted` hook events; none are
  in [[ADR-027 Installed Hook Set]].

## Options
- **Hooks for children** (install `SubagentStart`/`SubagentStop`, as the mockup proposed). Rejected once
  the transcript was read: it already says when each child starts and ends, including shells and
  monitors that have no hook at all, and a hook only reaches sessions Clinic launched — a detached
  agent's transcript is the only thing Clinic can read about it. Hooks would duplicate a signal the
  follower already has 250 ms later, and ADR-027 stays as it is.
- **Widen `TranscriptReader`'s tail.** Rejected: a tool use and its notification can be megabytes apart,
  and the scanner re-reads the whole head and tail of every changed transcript.
- **Follow only live transcripts incrementally.** Chosen.

## Decision
- **Three row styles**, `ClinicSessionRowStyle`: **Compact** (today's row, unchanged), **Cards** (every
  session) and **Automatic**, the default. Automatic gives a card to a session that is open in a tab,
  running detached, or has any child that is running, failed or needs you; everything else stays
  compact. Chosen in View ▸ Session Rows and in a sidebar toolbar menu beside collapse/expand. App-wide;
  Favorites follows it.
- **A card is a row, not a box**: no border or resting fill. The list's selection and the ADR-110 hover
  fill are its edges. Zones, each dropped when empty:
  - **Header** — the glyph column (shared `SessionLeadingGlyph`), the title on up to two lines, and badges
    plus a short age (`now`, `4m`, `3h`, `2d`, `5w`). Hover actions replace badges and age.
  - **Where and how** — branch, then for an open session the model ("Opus 5", from the `model`
    attachment, else `ModelName.display` of the id), effort, and context size ("85k context": input plus
    cache tokens of the last main-chain assistant message). A token count, not the mockup's gauge: the
    context window differs by model and alias and nothing in the transcript states it. *(Superseded:
    the CLI's status line input states it — [[ADR-157 The Status Line Reports Context]]; the token count
    is now the fallback.)*
  - **Now** — while working, the tool in flight and its target (a file tool shows the file name); while
    waiting for permission, *Allow Tool target?* in orange (primary on a selected row); while waiting
    for input, *Waiting for your input*; otherwise the recap, live or from `SessionSummary.recap`.
  - **Children** — hung off a hairline under the glyph column. Ordered: needs you, failed, running,
    quiet. Four rows show; past that, three and *N more*, which expands in place. Transcript children
    that completed or were stopped fold into one line, *2 agents · 1 shell finished*.
- **What counts as a child**, and what a click does (a click never changes the sidebar selection):
  | child | source | shows while | click |
  |---|---|---|---|
  | subagent | transcript `Agent`/`Task` | running or failed | replays `subagents/agent-<id>.jsonl` |
  | background shell | `Bash` + `run_in_background` | running or failed | opens the output file in a file window (ADR-081) |
  | monitor | `Monitor` | running or failed | same |
  | run | `RunStore.runs(inCheckout:)` | running; failed only while the session is open | the run pane (ADR-122) |
  | pull request | `summary.pullRequests` + `PRStore` mark | open; merged/closed stay in the badge | the PR pane |
  | Grill round | `openGrillRounds` | open (ADR-142) | the Grill pane |
  | panel terminal | a foreground job that is not the shell | the job runs | the terminal pane |
  | spawned session | `ClinicState.spawnedBy`, written by `start_session` | its tab is open | that session |
- **Status reuses [[ADR-096 Session Status Indicators]].** Running is the arc in `.secondary` with an
  elapsed timer when the start is known; needs you is the breathing orange dot; failed is the one new
  colour, red *failed ✕* (primary on a selected row). A failing PR check is *failed*, a pending one
  *running*. Nothing uses the accent.
- **A child that needs you raises the header glyph**: a session at rest (idle, exited, or not open) with
  a waiting Grill round or a spawned session waiting breathes orange like a waiting one. Failing checks
  do not raise it — [[ADR-128 Watching A Pull Request]] is how a PR asks for attention.
- **`SessionActivity` (ClinicCore)** folds transcript records into children, current tool, recap, context
  tokens and model. A notification is matched by tool-use id or task id and is idempotent. A denied or
  refused launch (an error result) is dropped. `TaskStop`'s result ends the task it names. A typed prompt
  clears finished children and the recap; a task notification is not a prompt. Sidechain records are
  ignored.
- **`TranscriptFollower` (ClinicCore)** keeps a byte offset and a partial last line, so each poll folds only
  what was appended. The first poll starts 8 MB from the end: opening a very long session stays cheap, at
  the cost of not seeing a child started before that window. A shrunk file starts over.
- **`SessionActivityStore` (app)** follows every session open in a tab or running detached. It reconciles
  that set every 2 s against a provider rather than being told at each open/close/rebind, watches the
  transcripts with `PathWatcher` (ADR-154, 250 ms debounce), and reads immediately on any hook.
- **`SessionSummary.recap`** is read from the tail (or from the head of a file with no tail), cleared by a
  later typed prompt, so a closed session's card has a now line too.
- **`GhosttySurfaceView.foregroundJobName`** (GhosttyBridge) names the terminal's foreground process group
  when it is not the shell, from `kinfo_proc.p_comm`. A card with a terminal pane re-reads it every 3 s,
  since a job starting produces no event.
- **`ClinicState.spawnedBy`** (child → parent) is written when `start_session` starts a session, and an
  entry whose transcript is gone is dropped on rescan.

## Consequences
- Verified in an isolated smoke instance (`CLINIC_APP_SUPPORT` + `CLAUDE_CONFIG_DIR`) against a synthetic
  transcript built from the probed shapes. Automatic promoted the live session and the one with an open
  round and left the third compact. The live card showed branch, Opus 5, 85k context, the recap, a failed
  shell first, three running children with timers, *2 more* expanding to five, and *1 agent finished*.
  Pressing a shell child opened its output in a file window. Cards and Compact rendered as described. The
  first run caught an unframed `SpinningArc` drawing at full row height and a closed session whose open
  round did not raise its glyph; both fixed.
- Not verified on a real key window: legibility of orange and red on a *focused* accent selection. The
  smoke window was never key, so the selection drawn was the grey unfocused fill.
- The transcript shapes are the CLI's, undocumented. A renamed tool or a new notification wrapper stops
  children from appearing (or ending) without an error; `SessionActivityTests` pins the shapes seen.
- One more `repeatForever` animation per running child (the arc) and per child that needs you (the dot).
  They exist only while something runs or waits, like the glyphs of ADR-096.
