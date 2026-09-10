---
tags: [research, libghostty, terminal]
date: 2026-09-07
---
# libghostty — status as of 2026-09-07

## Official status
- No tagged libghostty version yet; no separate repo. Built from `ghostty-org/ghostty` main. README: "We haven't tagged libghostty with a version yet… libghostty is already heavily in use." Doxygen: https://libghostty.tip.ghostty.org/
- Ghostty 1.3.0 (2026-03-09) extracted libghostty as a standalone Zig module with a work-in-progress C API; it "will have its own versioning and release schedule".
- Mitchell's roadmap (2025-09-22, https://mitchellh.com/writing/libghostty-is-coming): first lib is `libghostty-vt`; later `libghostty-<x>` for input, GPU rendering, GTK widgets and Swift frameworks.
- Mitchell (X, ~2026-07-02): "pure Swift Metal renderer and bindings for libghostty-vt… drop a package into their Swift/Xcode projects… Coming soon." **Not shipped** as of today.
- Version on main: `1.3.2-dev`, `minimum_zig_version = "0.16.0"`.

## Two layers exist
### A. `include/ghostty.h` — "libghostty-internal" (full embedding + Metal rendering)
Header says: "The only consumer of this API is the macOS app… tailored to the needs of the macOS app and not designed for external use… External embedders should instead use libghostty-vt." Undocumented, unversioned, can break at any commit. **This is what every shipping Swift/macOS embedder uses today.**

Key surface (verified from the header):
- App: `ghostty_init`, `ghostty_app_new(runtime_config, config)`, `ghostty_app_tick`, `ghostty_app_set_focus`, `ghostty_app_key`, `ghostty_app_update_config`, `ghostty_app_set_color_scheme`, `ghostty_app_needs_confirm_quit`, `ghostty_app_free`.
- Config: `ghostty_config_new/free/clone`, `load_cli_args`, `load_file`, `load_default_files`, `load_recursive_files`, `finalize`, `get`, diagnostics.
- Runtime callbacks (`ghostty_runtime_config_s`): `wakeup_cb`, `action_cb` (~60 action kinds: new window/tab/split, title, mouse shape, fullscreen, color scheme, search, scrollbar…), `read_clipboard_cb`, `confirm_read_clipboard_cb`, `write_clipboard_cb`, `close_surface_cb`.
- Surface config (`ghostty_surface_config_s`): `platform.nsview`, `scale_factor`, `font_size`, **`working_directory`, `command`, `env_vars`, `initial_input`, `wait_after_command`**, `context`. Per-surface command/cwd/env is supported.
- Surface: `new/free/draw/refresh/set_size/set_content_scale/set_focus/set_occlusion/set_display_id/process_exited/foreground_pid/tty_name/update_config`.
- Input: `surface_key`, `surface_text`, `preedit`, `mouse_button/pos/scroll/pressure`, `ime_point`.
- Clipboard/selection: `complete/deny_clipboard_request`, `has_selection`, `read_selection`, `read_text`; `binding_action`; splits.

Swift-side patterns (verified from `macos/Sources/Ghostty/*.swift`):
- One `ghostty_app_t` for the whole app. Sequence: config load → runtime cfg → `ghostty_app_new` → `set_focus`.
- `wakeup_cb` may fire on any thread → `DispatchQueue.main.async { ghostty_app_tick(app) }`.
- All libghostty calls on the main actor. `action_cb` is a big switch dispatched via NotificationCenter.
- `NSView` subclass forwards `set_size` on resize, `set_content_scale` on backing change, `set_focus`, `set_display_id`; `keyDown` → `interpretKeyEvents` (IME) → `ghostty_surface_key`.

### B. `include/ghostty/vt.h` — `libghostty-vt` (official, alpha)
Terminal state, render-state API for custom renderers, snapshots, formatter, search, OSC/SGR parsers, key/mouse/paste encoding, Kitty graphics. macOS/Linux/Windows/WASM. `zig build -Demit-lib-vt` → `ghostty-vt.xcframework`; also published on every tip build (`https://tip.files.ghostty.org/{COMMIT}/ghostty-vt.xcframework.zip`). Example: `example/swift-vt-xcframework`. **You bring your own renderer and PTY.** Official minimal example: Ghostling (libghostty-vt + Raylib).

## Build
- Zig lock-step per release: 1.2 → 0.14.1; 1.3 → 0.15.2; main → **0.16.0** (Homebrew has 0.16.0). "Each version of Ghostty is only guaranteed to build for one specific version of Zig."
- Needs Xcode + macOS SDK + iOS SDK + Metal Toolchain; `brew install gettext`. Nix optional.
- xcframework: `zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native|universal -Doptimize=ReleaseFast` → `zig-out/frameworks/GhosttyKit.xcframework`. Darwin host only. Trim flags used by libghostty-spm: `-Dcustom-shaders=false -Dinspector=false -Dsentry=false -Dapp-runtime=none`.
- Min macOS: 1.3 = 13+; main = **14+**.
- Build time undocumented; prior art caches the xcframework after a one-time multi-minute build.

## Prior art (Swift/macOS, full GhosttyKit embedding)
Curated list: https://github.com/Uzaaft/awesome-libghostty
- **cmux** (manaflow-ai) — Swift/AppKit agent workspace; ghostty *fork* as submodule with patches (hidden-tab GPU reclamation, selection/copy APIs, synchronous teardown). https://github.com/manaflow-ai/cmux — fork notes `docs/ghostty-fork.md`.
- **Supacode** — SwiftUI+AppKit agent command center; submodule + `make build-ghostty-xcframework`, Zig 0.15.2, macOS 26+. https://github.com/supabitapp/supacode
- **Cormac** (terhechte) — AppKit host, ACP agents, macOS 14. https://github.com/terhechte/Cormac
- **Termini** (arach) — SwiftUI wrapper, prebuilt xcframework via SPM from GitHub Releases, `patches/ghostty/`. https://github.com/arach/Termini
- **libghostty-spm** (Lakr233) — prebuilt `GhosttyKit.xcframework` SwiftPM binary target + `GhosttyTerminal` SwiftUI view; Zig 0.16. https://github.com/Lakr233/libghostty-spm
- **GhosttyKit** (briannadoubt) — SPM wrapper, vendored arm64 xcframework. https://github.com/briannadoubt/GhosttyKit
- Agent managers: agterm, Forge, Muxy, Zentty, moss, Factory Floor, Mori, GraphCode. Commercial: OrbStack, TheCommander, Nexion, Aizen.

## License
MIT. **Caveat:** `ghostty/shell-integration` scripts are GPLv3 — do not bundle them in an MIT app without checking. Tip xcframeworks are nightly, not tagged releases.

## Known embedding limitations
- Internal API: unstable, undocumented; header tells external embedders to use libghostty-vt.
- One app per process (inferred from Swift comment, not stated in C docs); main-actor only; wakeup re-dispatch; config finalized before `ghostty_app_new`.
- cmux fork notes: upstream lacks hidden-surface GPU release and some selection/copy APIs; teardown around `ghostty_surface_free` is delicate.
- Zig version lock-step; Xcode SDK slice mismatches can break a pinned Zig (Supacode note re Xcode 26.4).
- No thread-safety docs.
