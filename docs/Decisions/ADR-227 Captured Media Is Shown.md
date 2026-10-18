---
status: accepted
date: 2026-10-18
amends: "[[ADR-056 Session MCP Tools]] (what `show_image` says, and what the system prompt says about it)"
tags: [adr, mcp, media, prompt]
---
# ADR-227: Captured media is shown

## Context
User (2026-10-18): *"I have some sessions that just fail to send captured media (images/recordings/etc)
through the clinic tool."*

The transcripts in `~/.claude/projects` say the tool never failed. Every `show_image` call carried a valid
absolute `path`. The agents just did not call it:

| Project  | Sessions with captures | Captures | `show_image` calls | Sessions that showed nothing |
|----------|------------------------|----------|--------------------|------------------------------|
| clinic   | 17                     | 217      | 7                  | 16                           |
| Campfire | 8                      | 90       | 13                 | 6                            |
| cassette | 2                      | 57       | 0                  | 2                            |
| drop     | 2                      | 8        | 0                  | 2                            |

Campfire does best because `.claude/agents/campfire-device-tester.md` names `show_image`. So a rule works, but
only in projects that have one.

The cause is in Clinic. Claude Code defers MCP tools: until the agent loads a tool it sees only the tool's name
and the server's `instructions`. The instructions ([[ADR-131 The Grill Pane Answers A Round]]) carried a nudge
for `set_session_title`, `notify_user`, `report_to_parent` and `ask_round`, and nothing for `show_image`. The
trigger was in the tool's description ("screenshots, … screen recordings"), which the agent never sees until it
has already decided to use the tool.

## Decision
- **The instructions carry the trigger.** When `show_image` is offered, the system prompt says: *when you
  capture or make an image or recording the user would want to see — a screenshot or recording of a change, a
  simulator or device capture, a GIF, a diagram — call show_image with its absolute path in the same turn. A
  file you only saved or Read is invisible to them.* As with every other entry, it is left out when the user
  switches the tool off.
- **The description leads with when to use it,** then what it accepts. An agent that has loaded the tool reads
  the same trigger.
- The nudge is scoped to media *the user would want to see*. Captures an agent takes to check its own work
  during a smoke run are not meant to fill the Media pane.

## Rejected
- **A rule or skill per project.** It works (Campfire) but has to be repeated in every repository, and
  sessions in projects without one get nothing. Clinic owns the one channel into every session.
- **A PostToolUse hook that attaches the output of capture commands.** It would work even when the model
  ignores the instruction, but it means parsing shell commands for output paths, and it would show the
  self-check captures too. Kept in reserve in case the instruction is not enough.

## Consequences
- Only sessions started after the change get the new instructions. A running session keeps the system prompt
  it started with.
- Not yet measured: whether the show rate actually rises. Re-run the transcript tally after a week of use.
