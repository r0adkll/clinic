---
status: accepted
date: 2026-09-07
tags: [adr, build]
---
# ADR-007: Project Definition

## Context
Options are a hand-maintained `.xcodeproj`, XcodeGen, Tuist, or SPM-as-app with Xcode only for signing. Ghostty checks in an `.xcodeproj`.

## Decision
XcodeGen. `project.yml` is checked in; the generated `.xcodeproj` is gitignored. Installed via Homebrew.

## Consequences
- Readable diffs, agent-friendly, clean handling of the xcframework link and entitlements.
- A `make project` (or script) step precedes any Xcode build.
