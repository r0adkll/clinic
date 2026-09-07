# Clinic

Native macOS Claude Code session manager (a clean-room Collins reimplementation on libghostty).

## Before changing anything
- Design decisions are ADRs in the Obsidian vault `~/SoftwareProjects/vaults/clinic/Decisions/`. Read `Design/Design Tree.md` there first; it links every decision.
- Append a dated entry to `~/SoftwareProjects/vaults/clinic/Memory/Log.md` at the end of every working session.
- Any deviation from an ADR needs a new ADR (superseding the old one), not a silent change.

## Layout
- `project.yml` — XcodeGen spec. Run `make project` to regenerate `Clinic.xcodeproj` (gitignored).
- `Packages/ClinicCore` — models, JSONL reader, state machine, persistence. No AppKit/SwiftUI.
- `Packages/GhosttyBridge` — the only place `ghostty.h`/`GhosttyKit` is imported.
- `Sources/Clinic` — app target (SwiftUI + AppKit bridging).
- `Sources/clinic-hook` — helper executable bundled in the app; forwards hook payloads to Clinic's socket.
- `vendor/ghostty` — submodule pinned to v1.3.1. `scripts/build-ghostty.sh` emits `Packages/GhosttyBridge/GhosttyKit.xcframework`.

## Rules
- Swift 6 language mode, strict concurrency. All libghostty calls on the main actor.
- `~/.claude` is read-only (ADR-018).
- No third-party Swift packages (ADR-023).
- Never bundle `vendor/ghostty/src/shell-integration` (GPLv3).
