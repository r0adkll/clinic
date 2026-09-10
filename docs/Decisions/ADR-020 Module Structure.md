---
status: accepted
date: 2026-09-07
tags: [adr, architecture, build]
---
# ADR-020: Module Structure

## Decision
Four targets in one repo:
- **ClinicCore** (Swift package): Project/Session models, JSONL reader, session state machine, persistence, hook payload protocol. No AppKit or SwiftUI. Fully unit-tested.
- **GhosttyBridge** (Swift package): C module map for `ghostty.h`, the only place it is imported, plus the Swift wrapper (app, config, surface, action dispatch).
- **Clinic** (app target): SwiftUI views, AppKit bridging, stores.
- **clinic-hook** (executable target, bundled in the app): sends hook payloads to the socket ([[ADR-015 Hook Transport]]).

## Consequences
- GhosttyBridge is the swap point promised in [[ADR-008 libghostty Layer and Sourcing]].
- Core compiles without the xcframework, so its tests run fast and on any Mac.
