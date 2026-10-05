---
status: accepted
date: 2026-10-04
amends: "[[ADR-056 Session MCP Tools]] (`start_session` grows up and gains a sibling, `report_to_parent`), [[ADR-063 Session Lifecycle Controls]] (a second way to fork, with a prompt and a report), [[ADR-071 New Session Screen]] (a child variant of the sheet), [[ADR-156 Sessions Can Be Cards]] (a held report is a Now line), [[ADR-033 Notification Delivery]] (a held report notifies), [[ADR-059 Replay and Session Details]] (Details logs deliveries)"
tags: [adr, mcp, sessions, ui]
---
# ADR-182: A child session reports to its parent

## Context
User (2026-10-04): *"if I ask another session to create a new session / task and then report the result
back to the original session, can we support this?"* [[ADR-181 Sessions Have Parents]] gives the child a
place; this ADR gives it a voice. Decided in the same four grilling rounds; the user corrected the first
design in round 2.

What Clinic had: `start_session(prompt, directory, model)` ([[ADR-056 Session MCP Tools]]) opens a sibling
tab and returns at once. Nothing comes back.

Facts checked first, CLI 2.1.289:
- The CLI lists peer sessions on this Mac and lets one message another by name. From a Clinic session the
  peers appeared as `clinic-1f` and `chats-62`: the CLI's own names, which `claude agents --json` reports
  for interactive sessions and which `BackgroundAgentsService` already parses. `-n` sets one at launch;
  Clinic passes it only for detached launches (ADR-061).
- `--append-system-prompt <text>` exists, so a child can be briefed without touching the prompt it was given.
- Clinic's hooks are fire-and-forget (ADR-015): `clinic-hook` writes the payload and exits 0, printing
  nothing, so Clinic cannot block a `Stop` with a reason.
- Pasted input while the CLI is working is queued as the next prompt. Pasted input while a permission
  prompt is up is read as keys for that prompt (ADR-180).
- `MCPServer` answers each request on its own thread of a concurrent queue and gives up after 20 s; the
  shim's socket read gives up after 20 s too.

## Options
- **Clinic delivers the child's final message on every `Stop`.** Proposed in round 2 and rejected by the
  user: *"It's going to be near impossible to determine when the result is ready based on the mechanics
  of a session like Stop."* A Stop ends a turn that may be a question, a half-answer or a chat with the
  user; nothing in it says *this is the report*.
- **Native peer messaging only.** Rejected as the sole path: Clinic cannot see, hold, persist or log it,
  and a parent whose tab is closed is the CLI's problem.
- **A synchronous Stop hook** that blocks an unreported child's stop with a reason. Rejected: it changes
  the hook transport ADR-015 chose, for a reminder a paste can deliver.
- **A `final` flag** on the report tool. Rejected: a concept the model would get wrong half the time; the
  user can turn reporting off instead.
- **A timeout on the blocking variant.** Rejected: it picks a number for a job whose length the parent
  chose, and every row already has Stop.

## Decision
- **The child says when the result is ready**, by calling a new tool, **`report_to_parent(message)`**. It
  is listed only in a session that has a parent and reporting on. Every call is delivered; a child may
  report twice. The tool answers with what happened: delivered, or held and why.
- **Delivery is a paste into the parent's terminal** (`sendPastedLine`, the path Grill answers and runs
  use): one header line, *Report from child session "‹title›" (‹project›, ‹short id›):*, then the message
  verbatim as one prompt. Nothing is truncated; the CLI folds a long paste itself.
- **When the parent is ready**: at the prompt, or working (the CLI queues it). **Held** while the parent
  waits for permission or in a dialog, while its tab is closed or exited, while Clinic was relaunched
  in between, and while the user has turned reporting off for that child. Held reports live in
  `ClinicState.reports` (per parent, with their delivery time once delivered, capped), show on the
  parent's row and card as *Report from ‹child› waiting* in the Now zone, offer **Deliver Now** in the
  parent's context menu, deliver themselves when the parent is next at the prompt or resumed, and
  **notify** once through the existing path (*‹child› finished; report waiting for ‹parent›*; the
  notification reveals the parent, which delivers). An immediate delivery does not notify.
- **The reminder**: a child with reporting on that ends a turn (`Stop`) having never reported gets one
  pasted line, *Reminder from Clinic: you have not reported to your parent session. Call
  `report_to_parent` with your report now.* Once per child, visible in its transcript.
- **Report to Parent** is a toggle in the child's context menu. Off holds rather than drops. The child
  row shows nothing extra; the parent is where a report matters.
- **The brief** goes in `--append-system-prompt` for every spawned child: *You were started by Clinic
  session "‹title›" (peer name ‹name›) working in ‹dir›.* With reporting on it continues: *When your
  work is done, call `report_to_parent` with a report written for that session: what you did, what you
  found, what it should do next. For progress before then you may message ‹name› directly.* The prompt
  the parent or user wrote is typed unchanged.
- **`start_session`** gains `effort`, `fork` (resume the caller with `--fork-session` and the prompt; kind
  fork), `report` (default true) and `wait` (default false), and returns the child's session id and title.
  `model` and `effort` default to the parent's; the permission mode is never inherited. With `wait`, the
  tool call holds until the child's first report and returns it as the result, with no timeout; the
  parent's card reads *Waiting for ‹child›* with the elapsed timer; stopping or closing the child, or
  Clinic quitting, ends the call with an error result the parent can recover from. For that call alone
  the server and the shim wait without their 20 s limit. The first report of a waited child is the tool
  result and is not also pasted; later reports are.
- **New Child Session…** in a session row's context menu and the Session menu opens the New Session
  sheet with the parent shown, *Start as* fresh or a fork of the parent's conversation (a fork keeps the
  parent's directory), the prompt, the directory, model and effort pre-filled from the parent, and
  **Report back to parent** on by default. The instant Fork command of ADR-063 is unchanged: no prompt,
  no brief, no report.
- **Details** logs each report under *Lineage*: from whom, when it arrived, and when it was delivered or
  that it is still held.
- `report_to_parent` gets a Session Tools preference switch like every tool, on by default.

## Consequences
- A report is a user prompt in the parent's transcript and replay, headed so the parent and the reader
  both know what it is. The parent's `UserPromptSubmit` clears finished children and the recap as any
  prompt does (ADR-156).
- The child's brief names the parent by its CLI peer name, which Clinic reads from `claude agents --json`;
  if the poll has not seen the parent yet, the brief omits the peer sentence rather than guessing.
- `ClaudeLaunch` gains `appendSystemPrompt`; `clinic-hook`'s shim stops timing out a `tools/call` it is
  relaying, since Clinic's own guard answers everything but a waited call.
- Peer messaging stays the CLI's: Clinic neither sees nor records a message the child sends that way.
- Verification is recorded in [[Log]] when the branch lands.
