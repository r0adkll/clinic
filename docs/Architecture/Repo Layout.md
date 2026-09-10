---
tags: [architecture, build]
---
# Repo layout

Repo: https://github.com/r0adkll/clinic (public, MIT). Decisions: [[ADR-007 Project Definition]], [[ADR-020 Module Structure]], [[ADR-008 libghostty Layer and Sourcing]], [[ADR-014 libghostty Pin Target]], [[ADR-105 The Vault Lives In The Repo]].

```
clinic/
├── docs/                       Obsidian vault: Decisions/ (ADRs), Design/, Architecture/, Research/,
│                               Memory/Log.md, Backlog.md. Vault root; `.obsidian/` gitignored (ADR-105)
├── project.yml                 XcodeGen spec → Clinic.xcodeproj (gitignored)
├── Makefile                    setup / ghostty / project / build / test
├── scripts/build-ghostty.sh    zig build → Packages/GhosttyBridge/GhosttyKit.xcframework (gitignored)
├── vendor/ghostty/             submodule pinned to v1.3.1 (Zig 0.15.2)
├── Packages/
│   ├── ClinicCore/             models, TranscriptReader, SessionStateMachine, ClaudeLaunch, HookSettings,
│   │                           HookServer/HookClient, DirectoryWatcher, SessionScanner, StateStore. No AppKit.
│   └── GhosttyBridge/          the only `import GhosttyKit`. GhosttyConfig, GhosttyRuntime, GhosttySurfaceView, GhosttyAction.
├── Sources/Clinic/             app: ClinicApp, TabStore, SessionStore, HookService, NotificationService, views
├── Sources/clinic-hook/        helper executable embedded at Contents/MacOS/clinic-hook
├── Fixtures/local/             gitignored real transcripts for local regression (ADR-044)
└── .github/workflows/ci.yml    macos-15: cache xcframework by submodule sha + zig, core tests, app build
```

## Build
```
make setup && make ghostty && make project && make build
```
`build-ghostty.sh` reads `minimum_zig_version` from the submodule and looks for `/opt/homebrew/opt/zig@<major.minor>/bin/zig`. Requires the Xcode Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`). Output lands in `vendor/ghostty/macos/GhosttyKit.xcframework` and is copied into the bridge package (static `libghostty-fat.a` + headers + `module.modulemap` exporting `GhosttyKit`).

## Runtime data
- `~/Library/Application Support/Clinic/state.json` — [[ADR-021 Persistence]]
- `~/Library/Application Support/Clinic/hooks.json` — the `--settings` file ([[ADR-027 Installed Hook Set]])
- `~/Library/Application Support/Clinic/hook.sock` — [[Hook Protocol]]
- Reads `$CLAUDE_CONFIG_DIR` or `~/.claude/projects/**.jsonl` ([[ADR-018 Claude Data Write Policy]])
