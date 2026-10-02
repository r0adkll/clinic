---
status: accepted
date: 2026-10-02
amends: "[[ADR-015 Hook Transport]] (a second transport, preferred where the CLI can load it), [[ADR-027 Installed Hook Set]] (on that transport one settings hook is registered, not eleven), [[ADR-157 The Status Line Reports Context]] (on that transport Clinic registers no `statusLine`), [[ADR-166 Session State Has More Than One Witness]] (an interrupt now has a hook of its own)"
tags: [adr, architecture, hooks, mods]
---
# ADR-177: Hooks arrive through a mod

## Context
User (2026-10-02): *"Looks like Anthropic just released Claude Mods … can you check it out and suggest any
Clinic integrations"*, then *"This approach sounds good"* and *"lets start work on the mods integration"*.
This is the first of the steps agreed in [[Log]]: transport and status line. Built on branch `mods-integration`.

A mod is a plugin of function hooks that run inside Claude Code (CLI 2.1.287 and later). Facts measured
against 2.1.287, not read off the docs:

- `classic.<Event>` fires for every settings-hook event whether or not a settings hook is configured, and
  its input is the settings hook's stdin payload. `classic.PreToolUse` alone differs: its input is the tool's
  arguments.
- `$.http.fetch` takes a `socketPath` and reaches Clinic's hook socket, a path with a space in it included.
  It speaks HTTP only.
- `turn.complete` carries `reason`: `answer`, `aborted`, `refusal` or `error`. An interrupt fires no `Stop`.
- `$.session.usage()` gives the status line's context and rate-limit figures; `turn.step` names the model
  and effort of each request.
- A `--plugin-dir` mod receives its `userConfig` options from the `--settings` file's `pluginConfigs`.
- The CLI writes type declarations into `.claude-plugin/types/` of a mod it loads from a folder.

What this replaces costs: eleven command hooks start `clinic-hook` once per event, per tool call included
([[ADR-015 Hook Transport]]); an interrupt is noticed three seconds late by the terminal
([[ADR-166 Session State Has More Than One Witness]]); and Clinic's `statusLine` takes the place of the
user's own ([[ADR-157 The Status Line Reports Context]]).

## Options
- **Have the mod answer `classic.*` so the settings hooks beneath never run.** Rejected: that would silence the
  user's own settings hooks too.
- **Register both and drop duplicates in Clinic.** Rejected: every event would still start a process.
- **The mod calls `clinic-hook` through `$.process.run`.** Rejected: the same process per event, from inside.
- **An environment variable for the socket.** Rejected: automation launches have no surface environment, and
  the settings file already goes to every launch.
- **Run the mod from the app bundle.** Rejected: the CLI writes beside a mod it loads, which would break the
  bundle's signature.
- **One mod, chosen per launch by CLI version, with settings hooks kept as the fallback.** Chosen.

## Decision
- **Clinic ships a mod, `clinic-session`** (`Sources/clinic-mod`): `plugin.json`, `hooks.json` and
  `register.ts`, bundled in `Resources/clinic-mod`. `HookService` copies it at every launch to
  `mod.plugin` in Clinic's data directory (`mod-<pid>.plugin` for a second instance, swept like the
  suffixed settings files) and sessions load it with `--plugin-dir`.
- **The mod forwards and never changes an event.** Each of `SessionStart`, `UserPromptSubmit`,
  `PermissionRequest`, `PermissionDenied`, `Notification`, `Stop`, `StopFailure`, `PostModelSwitch`,
  `CwdChanged` and `SessionEnd` is sent as the CLI hands it over, then passed on with `next(e)`.
  `PreToolUse` is built from `tool.call`: the tool's name and the subagent it ran in, never its arguments.
  Every payload carries `_clinic_via: "mod"`.
- **Three things are new.** `StatusLine`, in the status line's own shape, after each main-loop request, at
  start and after a model switch. `TurnEnd`, with the reason the main loop's turn ended. `ModAttached`, once
  per process.
- **`TurnEnd` with `aborted` or `refusal` ends the turn**: `working` or `waitingForPermission` goes to `idle`
  at once. `answer` and `error` are left to `Stop` and `StopFailure`, which carry more.
- **The socket speaks both framings.** `HookWire` reads a bare JSON document closed by the client, as
  before, or an HTTP `POST` whose body is that document, answered `204`. One socket, one ordered queue.
- **Sends are chained in the mod**, so events arrive in the order they happened. State-making events retry
  after 100, 400 and 1500 ms; `PreToolUse` and `StatusLine` do not. A failure is swallowed. At
  `session.end` the mod waits up to a second for the chain to drain.
- **The settings file for a mod launch** (`hooks-mod.json` and its worktree twins) registers no `statusLine`
  and one hook, `SessionStart` through `clinic-hook probe`, which arrives as `CommandProbe`. It hands the mod
  its socket under `pluginConfigs`.
- **The transport is chosen when the app starts.** `claude --version` at 2.1.287 or later means the mod;
  anything else means settings hooks, exactly as before. The hidden preference `ClinicHookTransport` forces
  `mod` or `command`.
- **A mod that does not load is noticed.** If a `CommandProbe` is not followed within ten seconds by
  anything from the mod for that session, Clinic says so once in a notification, records the CLI version in
  `ClinicModFailedOnCLIVersion`, and launches on settings hooks until the CLI's version changes.
- **Automations stay on settings hooks.** They start detached with `--bg` and capture their settings path
  at launch; moving them is a later step.

## Consequences
- On the mod transport no helper process starts per event, and the user's own status line shows again in
  sessions Clinic launches. That last part is visible: ADR-157 had hidden it.
- The live effort level reaches Clinic with the next request, not the moment `/effort` changes it. The
  status line used to report that change at once.
- The status report names the model by id only. The card falls back to its own display name for it.
- A session whose mod did not load keeps its terminal and transcript witnesses and nothing else. The ones
  started after it are back on settings hooks.
- `disableAllHooks` stops the mod and the settings hooks alike, as it stopped the settings hooks before.
- The mod API is early access and moves between releases. The mod is one small file, type-checked against
  the declarations the CLI writes, with tests run by `claude plugin test` (`make test-mod`).
- Verified 2026-10-02 in Clinic Dev against CLI 2.1.287: a session launched with `--plugin-dir` and
  `hooks-mod.json`; the trace showed `SessionStart`, `ModAttached`, `CommandProbe`, `UserPromptSubmit`,
  `PreToolUse`, `PermissionRequest`, `Notification`, `Stop` and `TurnEnd`, all but the probe marked `mod`. A
  turn interrupted nine seconds in produced `TurnEnd` `aborted` at once and no terminal correction. Run
  headless against a test socket, the mod sent `StatusLine` with context, model and both plan windows.
  ClinicCore's 601 tests and the mod's 3 pass, and `claude plugin validate` passes.
- `/clear`, 2026-10-02: the user ran a working session in Clinic Dev and reported it works. The log has
  `session f1d287ed… cleared; tab follows 11a1589a…`, with no hook for an unknown session and no terminal
  correction in the three hours around it.
- Not verified: the fallback notice, since nothing here stops a mod from loading; `PostModelSwitch` through
  the mod; the sidebar card's figures by eye.
