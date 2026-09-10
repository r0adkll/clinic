---
status: accepted
date: 2026-09-07
tags: [adr, terminal, libghostty, build]
---
# ADR-014: libghostty Pin Target

## Context
Installed Ghostty is 1.3.1 (Zig 0.15.2). Ghostty main needs Zig 0.16 and macOS 14+, and has seven more action kinds. The v1.3.1 header already has `PROGRESS_REPORT`, `RING_BELL`, `PWD`, `COMMAND_FINISHED`, `initial_input`, `wait_after_command`, `env_vars`. Homebrew ships `zig@0.15`.

## Decision
Pin the submodule to tag `v1.3.1`. Zig 0.15.2 via `brew install zig@0.15`. Bump to 1.4 when it tags.

## Consequences
- The build script checks the Zig version against the submodule's `build.zig.zon` and fails loudly on mismatch.
- Refines [[ADR-008 libghostty Layer and Sourcing]].
