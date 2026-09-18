---
status: accepted (built 2026-09-18)
date: 2026-09-18
amends: "[[ADR-015 Hook Transport]] (who may bind the socket, what the helper does when it cannot connect), [[ADR-056 Session MCP Tools]] (the MCP socket follows the same rule)"
tags: [adr, architecture, hooks]
---
# ADR-167: The hook socket is not taken from a live instance

## Context
Same report as [[ADR-166 Session State Has More Than One Witness]]; this is the half that is about delivery.
Findings in [[Session State Reliability]].

- `HookServer.start` and `MCPServer.start` began with `unlink(socketPath)`. A second Clinic on the same
  Application Support directory (a Debug build beside the installed app) took both sockets, rewrote `hooks.json`,
  and unlinked the paths again when it quit. The first instance heard nothing until relaunch and never knew.
  This happened on 2026-09-08 and is the likeliest reading of "disconnect".
- `clinic-hook` connected once. A refused connection lost the event. The trace-file fallback of ADR-015 needs
  `CLINIC_HOOK_TRACE_DIR`, which no launched session has.
- The server reads each payload on its accept queue with a 5 s receive timeout, so one stalled helper held
  every session's events for 5 s. The status line (ADR-157) multiplied the traffic on that queue. The backlog
  was 64, and macOS refuses a connection outright when it is full.

## Options
- **A disk spool replayed at launch** (orca). Rejected: orca's terminals outlive the app, Clinic's die with it, so
  a replayed event would describe a process that is gone.
- **Refuse to launch a second instance.** Rejected: running a Debug build beside the installed app is how
  Clinic is developed.
- **Concurrent reads.** Rejected: `/clear` sends two events ten milliseconds apart whose order matters.

## Decision
- **The first instance keeps the plain names; any other gets its own.** `SocketClaim.instanceSuffix` connects
  to `hook.sock` before anything binds. If something answers, this process uses `hook-<pid>.sock`,
  `mcp-<pid>.sock`, `hooks-<pid>.json` and `hooks-<pid>-worktree-*.json`. Only the hook socket is probed: that
  server never writes to a client, whereas the MCP server answers every connection, and answering one that has
  gone raises `SIGPIPE`.
- **A suffixed instance removes its settings files on quit**, and `SocketClaim.sweepStale` removes at launch
  whatever a pid that is gone left behind.
- **`stop` unlinks the path only if it still holds the inode this server bound.**
- **The server watches its binding.** Every 5 s it compares the path's inode with its own. If the path is gone,
  or holds a socket nobody listens on, it binds again and logs an error saying hooks were lost in between. If
  another live process holds it (a build from before this ADR), it leaves it alone: fighting helps neither.
- **`clinic-hook` retries the connect**: 50, 100, 200, 400, 800, 1600, 3000 ms, which outlasts the watchdog.
  `PreToolUse` and `SessionEnd` get 50 and 150 ms only: the first confirms a state and never makes one, the
  second shares the CLI's 1.5 s exit budget and Clinic also hears of an exit from the surface. The status line
  does not retry. The hook `timeout` goes from 5 to 15; the hook is async, so the CLI waits for none of it.
- **The receive timeout is 1 s and the backlog 256.** Reads stay serial, in connection order.
- **`MCPServer` sets `SO_NOSIGPIPE`** on each client, so a shim that stopped waiting cannot kill the app.

## Consequences
- Verified with two smoke instances on one directory: the second came up on `hook-65022.sock` with its own three
  settings files, the first's socket stayed live through the second quitting, and the next launch swept what a
  killed instance had left.
- Two instances still share `state.json`. That is not new and not addressed here.
- A session keeps the socket path it was launched with. Hooks from a session whose instance is gone retry for
  six seconds in a background helper and then give up, which costs nothing anyone sees.
