---
status: accepted
date: 2026-10-04
amends: "[[ADR-003 Claude Code Integration Model]] (the integration stays CLI in a PTY, settings hooks and the transcript; function hooks are not a fourth leg)"
tags: [adr, architecture, hooks, mods]
---
# ADR-179: Clinic does not ship a mod

## Context
Claude Code 2.1.287 introduced mods: plugins of JavaScript function hooks that run inside the CLI and can
observe or change tool calls, prompts and turns, draw in the terminal, and answer a tool call themselves.
Between 2026-10-02 and 2026-10-04 a branch, `mods-integration`, built and verified three things on them
(its ADRs 177, 179 and 180 are in that branch's history, tagged `archive/mods-integration`):

1. A bundled mod that forwarded every settings-hook event from inside the CLI over HTTP on the hook socket,
   replacing eleven command hooks and the `statusLine` registration, with a reason for each turn's end, and a
   version check, a probe and a persisted fallback to settings hooks when the mod did not load.
2. Claude's own `AskUserQuestion` dialog mirrored into the Grill pane, answered there or in the terminal,
   whichever came first, the pane's answers returned as the tool's result over a held request.
3. Approve and Deny for permission prompts, which turned out to need no mod at all.

All of it worked. User (2026-10-04): *"TBH I'm not really seeing the 'Mods' value here and this ultimately
seems to just complicate the product."*, then *"Lets abandon this effort and cleanup this branch"*.

## Decision
- **Clinic ships no mod.** Hooks keep arriving through `--settings` and `clinic-hook`
  ([[ADR-015 Hook Transport]], [[ADR-027 Installed Hook Set]]); the status line keeps being Clinic's
  ([[ADR-157 The Status Line Reports Context]]); an interrupt keeps being noticed by the terminal
  ([[ADR-166 Session State Has More Than One Witness]]).
- **What needed no mod lands on `main`**: permission prompts answered from the card and the notification
  ([[ADR-180 Permission Prompts Are Answered From Clinic]]), the `PostModelSwitch` decoder reading the field
  the CLI sends, a log line per attention notice, the `-ClinicEnterAfter` smoke key, and *Has a question for
  you* on a card whose permission prompt is the question dialog.
- **Why.** The one capability only a mod gave, the question dialog in the pane, did not justify a second
  transport with a probe and a fallback, HTTP framing and held requests on the socket, a TypeScript file with
  its own test runner and type-check, a copy installed at every launch, and an API Anthropic calls early access
  and says moves between releases. Each CLI update would have been a risk the settings hooks do not carry.

## Consequences
- Clinic's integration with Claude Code stays three things: the CLI in a PTY, settings hooks, and the
  transcript. A fourth leg needs a benefit that reads as large as the cost above.
- Facts learned stay useful and are in the archived ADRs: `to_model`, `PostModelSwitch`'s shape; a `No` at the
  permission prompt is an interrupt with no `Stop` and no `PermissionDenied`; subagents have no
  `AskUserQuestion` tool on 2.1.289; the CLI writes type declarations beside a mod it loads.
- The branch is deleted; the tag keeps its commits reachable. Clinic Dev ([[ADR-176 Clinic Dev Is A Separate
  App]]) and the sidebar crash fix ([[ADR-178 The Usage Panel's Invitation Is Bounded]]) were on `main` already.
