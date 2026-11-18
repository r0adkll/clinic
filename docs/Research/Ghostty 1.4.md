---
tags: [research, libghostty, terminal]
date: 2026-11-17
---
# Ghostty 1.4: what changed for Clinic

Ghostty 1.4.0 is tagged (`83fb95624`, 3,245 commits after v1.3.1). Sources: the release notes
(https://ghostty.org/docs/install/release-notes/1-4-0), `git diff v1.3.1 v1.4.0 -- include/ghostty.h`, and the macOS
app's own adoption in `macos/Sources` at v1.4.0. Decision: [[ADR-235 Clinic Builds On Ghostty 1.4]].

## Build
- **Zig 0.17** (`minimum_zig_version = "0.17.0"`). Homebrew's `zig` is 0.17.1, and `zig@0.17` resolves to it.
  Installing it unlinks `zig@0.15` from `/opt/homebrew/bin`. The versioned keg stays at
  `/opt/homebrew/opt/zig@0.15/bin/zig` for older checkouts.
- Minimum macOS is still 13. 1.4 also supports macOS 27.
- Xcode 27.1 ships without the Metal Toolchain. Building fails with "cannot execute tool 'metal'" until
  `xcodebuild -downloadComponent MetalToolchain` runs. That is an Xcode change, not a Ghostty one.
- The xcframework build is unchanged: the same flags and the same `macos-arm64` slice.

## `ghostty.h`: breaking changes (all fixed in GhosttyBridge)
| Change | Effect on Clinic |
|---|---|
| `read_clipboard_cb` now gets the requested MIME types, a count and a `list` flag, and returns `ghostty_clipboard_read_result_e` (STARTED / UNAVAILABLE / UNSUPPORTED) | The callback was rewritten to serve only the requested representations. UNAVAILABLE lets a performable paste binding fall through, as `false` did. |
| `confirm_read_clipboard_cb` gets a `ghostty_clipboard_confirm_s` (contents, available types, `can_remember`) instead of a string | The handler still receives text: the `text/plain` representation, or a summary of what else would be disclosed. |
| `ghostty_surface_complete_clipboard_request(surface, const ghostty_clipboard_complete_s*, state)`, plus a new `ghostty_surface_deny_clipboard_request` | A denial is now explicit. Completing with an empty string is gone. |
| `ghostty_clipboard_content_s` gained `len`: data is binary-safe and **not NUL-terminated** | Writes are copied by length and set with `setData`. Reading them with `String(cString:)` would have overrun the buffer. |
| `ghostty_app_key_is_binding` removed, replaced by `ghostty_config_key_is_binding(config, key)` | `handleAppKeyEvent` asks the runtime's config. |
| Three action tags inserted **mid-enum** (`export_terminal_io`, `set_window_title`, `selection_changed`), two appended (`move_tab_to_new_window`, `resize_window`) | `GhosttyAction.tagNames` is indexed by raw value. A stale table would mislabel every tag after `render_inspector`, and `TabStore` matches `.unhandled(kind: "reload_config")` by name, so config reload would have stopped working. Tests now pin the table to the header. |
| `ghostty_input_trigger_s` lost the `translated` union member | Clinic only formats `physical`, `unicode` and `catch_all`. No change needed. |
| New clipboard location `GHOSTTY_CLIPBOARD_PRIMARY`, new request kinds `KITTY_READ`, `KITTY_WRITE`, `LIST`, new `OPEN_URL_KIND_OSC8` | Mapped. PRIMARY gets no pasteboard on macOS, as upstream does. Kitty reads and listings are denied by default, like OSC 52 reads. |

`ghostty_surface_text` keeps its paste semantics (bracketed when the program asks), so the composer and
`run_in_terminal` behave as before. Upstream's commit 550151882 says so explicitly.

A latent bug surfaced along the way: `confirm-close-surface` is an enum (`false`/`true`/`always`). `ghostty_config_get`
writes a string pointer for enums, and the tests read it through `bool(forKey:)`, which writes 8 bytes into a 1-byte
`Bool`. The tests passed on 1.3.1 by luck of the pointer's low byte. They now use `string(forKey:)`. No app code
reads an enum key that way.

## Free with the bump (no Clinic code)
- **Hidden surfaces release their GPU resources** (render targets, buffers, font textures, all
  triple-buffered; upstream's commit c4e16970a measures 1 visible and 20 hidden tabs). Clinic already reports occlusion through `ghostty_surface_set_occlusion`, so its
  background session tabs benefit at once. This is the patch cmux carried in its fork.
- **The display link parks while idle** and unfocused surfaces vsync only while dirty, so idle CPU use drops with many
  sessions open.
- **Scrollback compression** (`scrollback-compression = true` by default on macOS) compresses idle scrollback pages.
  Long Claude transcripts in many tabs are the case it helps.
- Kitty graphics now covers the whole published spec. Long OSC 9 and 777 notifications with multibyte text are no
  longer dropped. OSC 133 `click_events=2`. Unicode 18.
- `GHOSTTY_SURFACE_ID` is set in each child's environment.

## Behaviour changes users will notice
- **`copy-on-select` defaults to `none` on macOS** (it was effectively `clipboard`). Clinic loads the user's Ghostty
  config ([[ADR-009 Terminal Configuration Source]]), so Clinic terminals change with Ghostty.app. Anyone who wants
  the old behaviour sets `copy-on-select = clipboard` in their Ghostty config.
- **`⌘↑`/`⌘↓` run `jump_to_prompt` again** (top and bottom moved to `⌘Home`/`⌘End`). Clinic's own arrow chords all
  carry more modifiers (`⌘⌃↑`, `⌘⌥↑`, `⌘⌥⌃↑`), so nothing collides ([[ADR-173 Clinic's Chords Outrank Ghostty's
  Defaults]]).
- `scrollback-limit` is deprecated in favour of `scrollback-limit-bytes` and the new `scrollback-limit-lines`.

## Ported from the 1.4 macOS app (app-side, independent of the header)
- **Input-method commits are typed input, not pastes** (#13817). Before, dictation, the emoji picker and IMEs that commit
  without marked text went through `ghostty_surface_text`, so a program saw a bracketed paste. Claude Code collapses
  long pastes into `[Pasted text]`, so a dictated prompt arrived as a paste. `insertText` outside `keyDown` now sends
  a text-only key event, as upstream does.

## New integration surfaces worth adopting (not done in the bump)
1. **`ghostty_surface_foreground_pid` / `ghostty_surface_tty_name`.** libghostty finally exposes the pty.
   `GhosttyProcessProbe` rebuilds both from `sysctl` and matches children to surfaces *by creation order*, which can
   misattribute surfaces created back to back. `ttyName` and `foregroundPID` can come straight from libghostty.
   `foregroundJobName` still needs the shell's pid to tell "at the prompt" from "running a job". Compare the
   foreground group with the session leader instead of with login's first child. Worth an ADR of its own: it
   touches the busy-terminal logic behind `run_in_terminal` ([[ADR-198 The Panel Holds Several Terminals]]) and the
   card's busy terminals.
2. **`GHOSTTY_ACTION_SELECTION_CHANGED`.** Could drive an "Ask Claude about this selection" affordance, or Copy
   enablement, without polling `has_selection`.
3. **`ghostty_surface_paste_text`.** Paste that honours paste protection (confirms unsafe text). A candidate for text
   arriving from outside, such as drops and the Media pane. Today drops use `ghostty_surface_text`, which brackets
   but never confirms.
4. **Kitty clipboard protocol (OSC 5522).** A TUI can read and write non-text clipboard contents, images included,
   through the terminal. The bridge now serves any requested MIME type. Reads stay denied unless a
   `clipboardConfirmationHandler` allows them. If Claude Code ever reads images this way instead of through
   `osascript`, image paste over SSH would work in Clinic.
5. **OSC 7501 program status** (idle, working, done, blocked, failed). Squarely Clinic's domain, but libghostty only
   *parses* it: no apprt action reaches `ghostty.h`. Watch for an action in a later release. Clinic's state machine
   comes from hooks and the transcript, so this would be a cross-check, not a replacement.
6. `GHOSTTY_ACTION_EXPORT_TERMINAL_IO` exports the inspector's IO log. Clinic builds without the inspector, so
   there is nothing to do.

## libghostty itself
`libghostty-vt` now builds for every platform, ships an xcframework, CMake and pkg-config, and has 30+ examples,
Swift among them. It is still pre-1.0, with one more C API pass and an ABI break planned before a 1.0 tag. The
internal `ghostty.h` header now says outright that external embedders should use `libghostty-vt`.
[[ADR-008 libghostty Layer and Sourcing]] stands: `libghostty-vt` brings no renderer, and the Swift Metal renderer
Mitchell announced has not shipped. Revisit at libghostty 1.0.
