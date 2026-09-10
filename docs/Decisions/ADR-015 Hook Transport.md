---
status: accepted
date: 2026-09-07
tags: [adr, architecture, hooks]
---
# ADR-015: Hook Transport

## Context
Hooks are injected per launch with `--settings` (verified to merge with existing hooks, see [[Claude Code Hooks and Transcripts]]). The hook must deliver its JSON payload to Clinic. The CLI supports `command` and `http` hook types; command hooks can be `async`.

## Options
- (a) Bundled helper executable writing the payload to a Unix domain socket Clinic owns
- (b) Hook appends JSON lines to a per-session file Clinic watches
- (c) `http` hook to a localhost port

## Decision
(a). POSIX socket plus `DispatchSource`, no dependencies. Socket path under Clinic's Application Support directory. The helper (`clinic-hook`) is a second executable target inside the app bundle, invoked with `async: true` so it never delays the CLI. (b) is the fallback when the socket is unavailable and doubles as a debug trace. (c) rejected: a TCP port is reachable by any local process and needs collision handling.

## Consequences
- Clinic must locate its own bundle path at launch to write the hook command into the `--settings` JSON.
- The socket protocol is newline-delimited JSON, one payload per connection.
