---
status: accepted
date: 2026-09-09
supersedes: the WorktreeCreate entry of ADR-027
tags: [adr, hooks, git]
---
# ADR-098: WorktreeCreate is not a notification hook

## Context
[[ADR-027 Installed Hook Set]] registered `clinic-hook` for every event Clinic could name, `WorktreeCreate`
among them, on the assumption that they are all notifications: the helper forwards the payload to Clinic's
socket, prints nothing, exits 0. `WorktreeCreate` was used only as a hint that a tab had moved to another
repository, so [[ADR-080 Diff Panel]]'s cached repo root could be forgotten.

`WorktreeCreate` is not that kind of hook. The CLI documents it as *replacing default git behavior*:
registering a command hook hands worktree creation to that command, which is then expected to print the
new path (or return `hookSpecificOutput.worktreePath`). A helper that prints nothing therefore does not
"observe" worktree creation — it *is* the worktree creation, and an empty one. Every `-w` launch from
Clinic died on:

> Error creating worktree: WorktreeCreate hook failed: hook succeeded but returned no worktree path

Reproduced 2026-09-09 in a scratch repo with Clinic's own `--settings` file; dropping the event from that
file and rerunning the identical command created the worktree.

Considered and rejected: making `clinic-hook` do the `git worktree add` itself and echo the path. That
would give Clinic control of worktree placement and naming, but it makes the helper — deliberately a dumb
forwarder — own a git operation, and buys nothing over what the CLI already does.

## Decision
- `HookSettings.events` installs **notification events only**. `WorktreeCreate` is not among them, and any
  future event whose contract is "replaces the default behaviour" stays out for the same reason.
- The signal it was carrying is already elsewhere: `SessionStart` reports the *worktree* as its `cwd`, and
  `SnapshotService` resolves a session's repo root from the event's own `cwd`, so a worktree session
  resolves the right repository on its first event. `CwdChanged` still forgets a cached root for a
  mid-session `cd`.

## Consequences
- `TabStore.handle(hookEvent:)` loses its two `WorktreeCreate` branches; `LaunchTests` asserts the event is
  never registered, so a future "register everything" edit fails a test instead of breaking `-w` silently.
- Clinic must be restarted for a changed hook set to reach `hooks.json` (`HookService` writes it at launch).
