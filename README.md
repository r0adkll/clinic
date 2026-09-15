# Clinic

A native macOS app for managing Claude Code sessions: every session in a sidebar, each one running the real `claude` CLI in an embedded [Ghostty](https://ghostty.org) terminal, with live state from Claude Code hooks.

Clinic is a clean-room macOS reimplementation of [Collins](https://github.com/episode6/collins).

## Install

Apple Silicon, macOS 15 or later. Clinic runs the `claude` CLI, which must be on your `PATH`.

```sh
brew install --cask r0adkll/tap/clinic
```

Or download `Clinic-<version>.zip` from the [latest release](https://github.com/r0adkll/clinic/releases/latest). Builds are Developer ID-signed and notarized.

## Status

0.x: usable daily by its author, and the shape of things may still change between minor versions.

## Building

Requirements: macOS 15+, Xcode 26, Homebrew.

```sh
make setup      # installs xcodegen + zig@0.15, checks out the ghostty submodule
make ghostty    # builds GhosttyKit.xcframework from vendor/ghostty (one-time, several minutes)
make project    # generates Clinic.xcodeproj
make build      # builds the app
make test       # runs the test suites
```

Releasing: bump `MARKETING_VERSION` in `Version.xcconfig`, commit, then `make publish` — a guided flow that builds and notarizes, launches the app for a smoke test, drafts the notes, tags, creates the GitHub Release and updates the Homebrew cask. `make release` alone produces the notarized zip.

## Documentation

`docs/` is an Obsidian vault holding the design: an ADR per decision in `docs/Decisions/`, a one-page
summary in `docs/Design/Design Tree.md`, architecture and research notes, and a running log. It reads
fine as plain Markdown; open `docs/` as a vault if you want the wikilinks and graph.

## License

MIT. Ghostty is MIT; its shell-integration scripts are GPLv3 and are not bundled.
