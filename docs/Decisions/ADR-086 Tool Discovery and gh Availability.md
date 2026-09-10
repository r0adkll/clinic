---
status: accepted
date: 2026-09-08
tags: [adr, github, process, diagnostics]
---
# ADR-086: Find the user's CLIs through their login shell, and say which way `gh` failed

## Context
The PR panel reported "GitHub CLI not available — install `gh` and run `gh auth login`" on a machine
where `gh` was installed *and* authenticated. Two separate defects stacked up.

**Finding the binary.** A GUI app launched from Finder or the Dock inherits launchd's
`/usr/bin:/bin:/usr/sbin:/sbin` — not the `PATH` the user's terminal has.
`ProcessEnvironment.toolPaths` compensated with a hardcoded prepend of `/opt/homebrew/bin`,
`/usr/local/bin` and `~/.local/bin`. On this machine `gh` lives at `~/.nix-profile/bin/gh`, which is
in none of them, so `/usr/bin/env gh` exited 127. Reproduced directly: under
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `gh auth status` exits 127 with the old prefixes and 0 with the
login shell's `PATH`. [[ADR-084 Plugin Marketplace]] had already hit this once and answered it by
adding `~/.local/bin` to the list; nix is the second miss, and mise, asdf, pkgx and Volta are queued
behind it. Growing the constant is losing this race one package manager at a time.

**Reporting the failure.** `GitHubService.isAvailable()` returned `Bool`, collapsing "no `gh` on
PATH" and "`gh` is not logged in" into one value. The panel had one message for both, and it named
the fix for the case that was not happening. A user who is logged in is told to log in, which is a
dead end — there is nothing to try.

## Options
1. **Add `~/.nix-profile/bin` to `toolPaths`.** One line, fixes this machine, loses to the next
   package manager. Rejected on the same grounds ADR-084 should have been.
2. **A `gh` path preference.** Configuration is the user doing the app's job; and it would need a
   twin for `claude` and `git`.
3. **Ask the login shell.** It already knows, because it is what builds the `PATH` the terminal has.

## Decision
- **`PATH` gains a third layer: the login shell's own.** `ProcessEnvironment.loginShellPath` runs
  `$SHELL -l -c '/usr/bin/printenv PATH'` once per launch and caches it. `printenv` rather than
  `echo $PATH` because fish keeps `PATH` as a list and would print it space-separated. *Login*, not
  interactive: an interactive shell can block on a prompt, and the hardcoded prefixes already cover
  the rc-file-only case (zsh's `-l -c` skips `.zshrc`, which is exactly where `~/.local/bin` lives).
  Failures — no `SHELL`, a shell that errors, one that takes over 3 s — return empty and leave the
  old behaviour intact.
- **Order is prefixes, inherited, login shell**, de-duplicated. Inherited beats the login shell so a
  deliberately narrowed `PATH` (a test, a wrapper) still shadows the everyday one.
- **Resolved at launch, off the main thread.** `ProcessEnvironment.prewarm()` from
  `applicationDidFinishLaunching`, so the first `gh`/`git`/`claude` call does not pay the ~0.5 s.
- **`isAvailable() -> Bool` becomes `availability() -> Availability`**: `.ready`,
  `.notInstalled(searchedPath:)`, `.notAuthenticated(String)`. Exit 127 (or a launch failure) is
  "missing"; any other non-zero exit means `gh` ran and objected, so it is a login problem and its
  own stderr is carried through — `gh` words it better than we would.
- **The panel says which one it is**, and offers **Retry** rather than requiring a relaunch, so a
  `gh auth login` in another window is picked up. The missing-`gh` message can disclose the `PATH`
  actually searched, because "it isn't on the PATH" is not actionable without knowing what that was.

## Consequences
- Every CLI wrapper benefits, not just `gh`: `GitInfo`, `GitRepository`, `FileIndex`, `PluginService`,
  `BackgroundAgents` and `ProjectIconGenerator` all build their environment through
  `ProcessEnvironment.withToolPaths()`.
- ADR-084's `~/.local/bin` entry stays. It is now a fallback rather than the mechanism, and it still
  earns its place: zsh login shells do not source `.zshrc`, so the shell layer misses it.
- Clinic now spawns the user's login shell once at startup. That is the same shell
  [[ADR-016 Launch Shape]] already spawns per session, so no new trust or config surface.
- Verified end to end in a smoke instance: `gh` unreachable renders "Can't find the gh CLI" with the
  searched `PATH`; an empty `GH_CONFIG_DIR` renders "gh isn't logged in" quoting gh's own stderr.
