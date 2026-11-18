---
status: accepted (built 2026-11-17)
date: 2026-11-17
supersedes: "[[ADR-014 libghostty Pin Target]]"
tags: [adr, terminal, libghostty, build]
---
# ADR-235: Clinic builds on Ghostty 1.4

## Context
[[ADR-014 libghostty Pin Target]] pinned v1.3.1 with Zig 0.15.2 and said to bump "when 1.4 tags". User (2026-11-17):
*"It looks like Ghostty 1.4.0 is released. We should prepare Clinic for updating to it and evaluating any new
features or integration surfaces."* What changed, and what it means for Clinic, is in [[Ghostty 1.4]].

The internal `ghostty.h` API broke in five places Clinic uses: the read and confirm clipboard callbacks, completing
a clipboard request, binary-safe clipboard content, and `ghostty_app_key_is_binding`. The action enum also grew in
the middle. Ghostty 1.4 needs Zig 0.17.

## Decision
- **Pin `vendor/ghostty` to tag `v1.4.0`** (`83fb95624`). Build with Zig 0.17 (`brew install zig@0.17`, which today
  resolves to Homebrew's `zig`).
- **`scripts/build-ghostty.sh` accepts any patch release of the required Zig minor series** at or above
  `minimum_zig_version`. Homebrew ships 0.17.1, and the exact-match check refused it. It looks in
  `/opt/homebrew/opt/zig@<series>`, then `/opt/homebrew/opt/zig`, then `PATH`.
- **GhosttyBridge adopts the 1.4 clipboard contract.** Reads serve only the MIME types libghostty asks for, plus a
  type listing when asked. Writes are copied by length. A refusal goes through `ghostty_surface_deny_clipboard_request`.
  `GhosttyClipboardRequest` gains `kittyRead`, `kittyWrite` and `list`. With no handler installed, the policy is
  `allowedByDefault`: a user's paste and a program's write go through, a program's read or listing does not. That
  is the old OSC 52 policy extended to Kitty's protocol.
- **App-level key bindings are checked with `ghostty_config_key_is_binding`** against the runtime's config.
- **`GhosttyAction.tagNames` matches the 1.4 header**, and a test pins its first, middle and last entries and its
  length to the C enum. The table is indexed by raw value, so any future insertion that the table misses fails a test
  instead of silently renaming actions.
- **Input-method text committed outside `keyDown` is sent as a text-only key event**, not through
  `ghostty_surface_text`, which ports upstream's #13817. Dictated prompts reach Claude Code as typed input rather
  than as a bracketed paste.
- **Clinic does not override 1.4's new defaults.** `copy-on-select` (now `none` on macOS) and `⌘↑`/`⌘↓` →
  `jump_to_prompt` follow the user's Ghostty config, as [[ADR-009 Terminal Configuration Source]] has it. Neither
  collides with a Clinic chord.
- The new surfaces (`foreground_pid`/`tty_name`, `selection_changed`, `paste_text`, OSC 7501) are **not** adopted
  here. Each changes behaviour beyond the bump and gets its own ADR. They are listed in the Backlog.

## Consequences
- Upgrading needs Zig 0.17 *and*, on Xcode 27.1, the Metal Toolchain component
  (`xcodebuild -downloadComponent MetalToolchain`). `make setup`, the README and CI install `zig@0.17`, and the CI
  cache key names Zig 0.17.
- Installing Homebrew's `zig` unlinks `zig@0.15` from `PATH`. A checkout still on v1.3.1 finds it at
  `/opt/homebrew/opt/zig@0.15/bin/zig`.
- Background session tabs release their GPU resources while hidden, and idle surfaces stop their display link. Both
  come with no Clinic code, because Clinic already reports occlusion.
- Kitty clipboard reads and listings are refused unless a host installs a `clipboardConfirmationHandler`. Clinic
  installs none today.
- Checked: GhosttyBridge's 11 tests pass against the 1.4.0 xcframework, Clinic Dev builds, and a Claude Code session
  started in Clinic Dev renders in a 1.4 surface, the shell prompt and OSC 8 links included, with no Ghostty
  errors in the unified log. Not checked by hand: dictation, Kitty clipboard reads, and paste protection prompts.
