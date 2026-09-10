---
status: accepted
date: 2026-09-07
tags: [adr, terminal, libghostty]
---
# ADR-008: libghostty Layer and Sourcing

## Context
See [[libghostty]]. Two layers exist: the internal full-embedding C API (`include/ghostty.h`, with Metal rendering, used by every shipping Swift embedder but explicitly 'not designed for external use') and the official alpha `libghostty-vt` (terminal state only; bring your own renderer and PTY). Mitchell announced a Swift Metal renderer for libghostty-vt in July 2026; it has not shipped. Ghostty main needs Zig 0.16.0; each release builds with exactly one Zig version.

## Options
- Layer: (a) internal `ghostty.h` API; (b) libghostty-vt plus own renderer; (c) wait for the official Swift package
- Sourcing: build from a pinned source checkout; vendor a prebuilt xcframework; depend on a third-party SPM wrapper

## Decision
Layer (a). Sourcing: Ghostty repo as a git submodule pinned to the exact commit the installed `/Applications/Ghostty.app` was built from; an initially empty `patches/ghostty/` directory; a build script that installs the matching Zig via Homebrew if missing and emits `GhosttyKit.xcframework` (gitignored). Supacode and Cormac are the reference implementations; cmux is consulted but not copied because it depends on a diverged fork.

## Consequences
- Every libghostty call is isolated in one Swift module so a later move to the official Swift package touches one directory.
- Upgrades are a submodule bump plus a Zig bump.
- Do not bundle `ghostty/shell-integration` resources: they are GPLv3.
- Revisit if official prebuilt releases appear.
