# Clinic

Native macOS Claude Code session manager (a clean-room Collins reimplementation on libghostty).

## Before changing anything
- Design decisions are ADRs in `docs/Decisions/` (the repo's Obsidian vault, ADR-105). Read `docs/Design/Design Tree.md` first; it links every decision.
- Append a dated entry to `docs/Memory/Log.md` at the end of every working session.
- Any deviation from an ADR needs a new ADR (superseding the old one), not a silent change.

## Layout
- `docs/` — the Obsidian vault: ADRs, design tree, architecture notes, research, log, backlog. Open `docs/` as the vault root.
- `project.yml` — XcodeGen spec. Run `make project` to regenerate `Clinic.xcodeproj` (gitignored).
- `Packages/ClinicCore` — models, JSONL reader, state machine, persistence. No AppKit/SwiftUI.
- `Packages/GhosttyBridge` — the only place `ghostty.h`/`GhosttyKit` is imported.
- `Sources/Clinic` — app target (SwiftUI + AppKit bridging).
- `Sources/clinic-hook` — helper executable bundled in the app; forwards hook payloads to Clinic's socket.
- `vendor/ghostty` — submodule pinned to v1.3.1. `scripts/build-ghostty.sh` emits `Packages/GhosttyBridge/GhosttyKit.xcframework`.

## Rules
- Swift 6 language mode, strict concurrency. All libghostty calls on the main actor.
- `~/.claude` is read-only (ADR-018).
- Third-party Swift packages are allowed when they replace substantial work, and each adoption is recorded in ADR-058 (which superseded ADR-023's "no dependencies"). `ClinicCore` stays Foundation-only; packages attach to the app target.
- Never bundle `vendor/ghostty/src/shell-integration` (GPLv3).
