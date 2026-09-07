# Clinic

A native macOS app for managing Claude Code sessions: every session in a sidebar, each one running the real `claude` CLI in an embedded [Ghostty](https://ghostty.org) terminal, with live state from Claude Code hooks.

Clinic is a clean-room macOS reimplementation of [Collins](https://github.com/episode6/collins).

## Status

Pre-0.1. Milestone 1 (sidebar, open/resume, new session, hook-driven state, notifications) is in progress.

## Building

Requirements: macOS 15+, Xcode 26, Homebrew.

```sh
make setup      # installs xcodegen + zig@0.15, checks out the ghostty submodule
make ghostty    # builds GhosttyKit.xcframework from vendor/ghostty (one-time, several minutes)
make project    # generates Clinic.xcodeproj
make build      # builds the app
make test       # runs the test suites
```

## License

MIT. Ghostty is MIT; its shell-integration scripts are GPLv3 and are not bundled.
