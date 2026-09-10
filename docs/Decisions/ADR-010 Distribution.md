---
status: accepted
date: 2026-09-07
tags: [adr, release]
---
# ADR-010: Distribution

## Context
The App Store sandbox makes PTY spawning and arbitrary git worktrees impractical.

## Decision
Developer ID signing plus notarization, distributed as a direct download and a Homebrew cask. No App Store. Sparkle updates are a milestone 2+ concern. The author is enrolling in the Apple Developer Program (in progress on 2026-09-07).

## Consequences
- 2026-09-07: builds are Apple Silicon only (`ARCHS = arm64`) because the pinned GhosttyKit.xcframework is built `native`; a universal release needs `GHOSTTY_XCFRAMEWORK_TARGET=universal` in `build-ghostty.sh` and `ARCHS` widened.
- Until the Developer ID certificate exists, builds are ad-hoc signed and local only.
- Release automation lands with the first tagged version.
