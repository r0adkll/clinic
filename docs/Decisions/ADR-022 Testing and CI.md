---
status: accepted
date: 2026-09-07
tags: [adr, testing, ci]
---
# ADR-022: Testing and CI

## Decision
- Swift Testing for ClinicCore, with fixture JSONL transcripts captured (and scrubbed) from real sessions.
- No UI tests in milestone 1.
- One XCTest in GhosttyBridge that instantiates a real libghostty app and surface headlessly, to catch upstream API breaks on a submodule bump.
- GitHub Actions on a macOS 15 runner: build the xcframework once, cached by submodule commit plus Zig version; run tests; build the app.

## Consequences
- Fixture scrubbing script lives in the repo.
- CI time is dominated by the first xcframework build; cache hits make later runs fast.
