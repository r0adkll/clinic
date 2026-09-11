# Session log

## 2026-09-07 — Project kickoff
Vault created at `~/SoftwareProjects/vaults/clinic`, layout mirrors the Ditto vault (Home, Design Tree, Decisions/ADRs, Architecture, Research, Log, Backlog). Project dir `~/SoftwareProjects/main/clinic` is empty. Research dispatched on Collins and libghostty. Grilling session started.

## 2026-09-07 — Grilling session, round 1
Research filed: [[Collins]] (GTK4/Python, ~37k lines, GPL-3, PTY + screen-scraping state detection, huge feature surface) and [[libghostty]] (internal `ghostty.h` API is what all Swift embedders use; libghostty-vt is the official alpha layer; no Swift package shipped yet).
Settled: audience (ADR-001), Collins as M1 spec (ADR-002), hybrid CLI+hooks+JSONL integration (ADR-003), agent scope (ADR-004), SwiftUI+AppKit (ADR-005), macOS 15 / Swift 6 strict (ADR-006), XcodeGen (ADR-007), libghostty internal API via pinned submodule (ADR-008), user's Ghostty config + overrides (ADR-009), Developer ID + cask (ADR-010), repo/name/MIT (ADR-011), Ditto process (ADR-012).
Facts found for round 2: `claude --settings <file-or-json>` injects hooks per launch; `--session-id <uuid>` lets Clinic pre-assign ids; `-n/--name` sets a display name; libghostty main emits `PROGRESS_REPORT`, `RING_BELL`, `PWD`, `COMMAND_FINISHED` actions and surfaces accept `command`, `working_directory`, `env_vars`, `initial_input`, `wait_after_command`. Installed Ghostty is 1.3.1 (Zig 0.15.2).
Next: milestone 1 slice, state detection mechanism, launch shape, session identity, ~/.claude write policy, surface lifetime model, module structure, persistence, testing/CI, milestones/versioning, libghostty pin target.

## 2026-09-07 — Grilling session, round 2
Research filed: [[Claude Code Hooks and Transcripts]] (32 hook events, 12 notification types, handler types, flags). Verified locally: `--settings` hooks merge with existing hooks; `--session-id` creates a new session with a chosen UUID.
Settled: M1 slice (ADR-013), pin v1.3.1 (ADR-014), hook transport (ADR-015), launch shape (ADR-016), session identity (ADR-017), read-only `~/.claude` (ADR-018), window/surface lifetime (ADR-019), module structure (ADR-020), persistence (ADR-021), testing/CI (ADR-022), zero deps (ADR-023), versioning (ADR-024), vocabulary (ADR-025).
Next: state machine + hook set, outside sessions, discovery, grouping, naming, config overrides + shell integration, action callbacks, new-session flow, notifications, shortcuts, close/quit, exited sessions, preferences, logging, build order.

## 2026-09-07 — Grilling session, round 3
Settled: state machine (ADR-026), hook set (ADR-027), outside sessions (ADR-028), discovery (ADR-029), grouping (ADR-030), naming (ADR-031), new-session flow (ADR-032), notifications (ADR-033), config overrides + shell integration (ADR-034), action scope (ADR-035), shortcuts (ADR-036), close/quit/exited (ADR-037), prefs/diagnostics (ADR-038), build order (ADR-039).
Next (round 4, small): sidebar ordering/visuals, one-tab-per-session, launch restoration, concurrency model, fixture strategy.

## 2026-09-07 — Grilling session, round 4 (final)
Settled: sidebar ordering/visuals (ADR-040), one tab per session (ADR-041), launch restoration (ADR-042), concurrency model (ADR-043), fixture strategy (ADR-044). Design tree frontier empty; 44 ADRs. Backlog seeded by milestone. Awaiting user confirmation of shared understanding before any implementation.

## 2026-09-07 — Implementation, milestone 1 (steps 1–5 first pass)
Repo bootstrapped at `~/SoftwareProjects/main/clinic`, public at https://github.com/r0adkll/clinic. See [[Repo Layout]], [[Hook Protocol]], [[Terminal Integration]].
- Step 1: XcodeGen spec, ghostty submodule v1.3.1, `scripts/build-ghostty.sh` (needed `brew install zig@0.15 gettext` and `xcodebuild -downloadComponent MetalToolchain`), CI workflow. Build script bug found and fixed: v1.3.1 emits the xcframework at `vendor/ghostty/macos/GhosttyKit.xcframework`, not `zig-out/frameworks/`.
- Step 2: GhosttyBridge written by a subagent against Ghostty's own Swift sources; 4 XCTests including a real headless surface lifecycle. Deviations from the ADR-034 plan: libghostty has no unbind-by-action, so the bridge resolves each action's trigger with `ghostty_config_trigger` and writes `keybind = <trigger>=unbind` in rounds. Linker needs `c++` + AppKit, Carbon, CoreFoundation, CoreGraphics, CoreText, CoreVideo, IOSurface, Metal, QuartzCore, UniformTypeIdentifiers. v1.3.1 quirks: explicit `command` forces wait-after-command; the Swift view must not set `wantsLayer` (Zig installs an IOSurfaceLayer); `wakeup` arrives off-main, everything else on main; no C API for foreground pid/tty (bridge uses sysctl).
- Step 3: ClinicCore — models, TranscriptReader (head 256 KB / tail 64 KB, tolerant), SessionStateMachine, ClaudeLaunch + HookSettings, StateStore, SessionScanner, DirectoryWatcher. 24 Swift Testing tests with a synthetic fixture builder.
- Step 4: HookServer (POSIX Unix socket + DispatchSource), `clinic-hook` helper (always exits 0, trace-file fallback), verified with real `claude -p` runs: hooks passed via `--settings` merge with existing hooks; `--session-id` creates a new session with a chosen UUID.
- Step 5: TabStore, SessionStore, HookService (+ hidden `ClinicHookTrace` default), NotificationService, sidebar, new-session sheet, exited overlay, ⌘N/⌘T/⌘W/⌘⇧[]/⌘1–9. Hidden smoke keys `ClinicOpenShellOnLaunch`, `ClinicNewSessionOnLaunch <path>`.
Verified on screen: shell renders in-window with the user's Ghostty config; a session started from Clinic with a pre-assigned id received its SessionStart hook and showed the idle glyph; title follows pwd. Fixed on the way: helper must be copied to `Contents/MacOS` (XcodeGen `copy.destination: executables`); pending rows were dropped on rescan; Clinic launched from inside a Claude session inherited `CLAUDE_CODE_CHILD_SESSION` (now scrubbed at launch).
Not yet verified by hand: working/waiting transitions and notifications during a real conversation; close/quit prompts; Resume after exit. Synthetic hooks drove working → waitingForPermission → idle correctly (glyphs confirmed). CI: run 1 failed only because the skeleton commit had no app sources; runs 2 and 3 green on macos-15 (xcframework built on the runner, ~6–8 min uncached).

## 2026-09-07 — Milestone 1 rough edges, batch 1
User confirmed the first build works. Fixed: launch commands are typed at the prompt via `GhosttySurfaceView.sendLine` (text + synthesized Return, keycode 36) on the first `pwd` action or a 700 ms fallback — `ghostty_surface_text` alone does not submit a newline, and `initial_input` wrote before the shell was ready; `GHOSTTY_RESOURCES_DIR` now points at `/Applications/Ghostty.app/Contents/Resources/ghostty` when present (ADR-034), which fixed both fish shell integration and the user's `theme = Dracula` lookup; sidebar selection keyed by session/tab id; one retry + alert on `ghostty_surface_new` failure (one OutOfMemory seen once, 0/5 on a repeat loop); `make test` runs both package suites.
Diagnostics gotcha: on this machine `log` is shadowed in fish — use `/usr/bin/log show --info --predicate 'subsystem == "com.r0adkll.clinic"'`. libghostty logs under subsystem `com.mitchellh.ghostty`. Notification permission is granted (`auth granted=true`).
Verified on screen: `❯ claude --session-id …` appears at the prompt, Claude Code banner renders, SessionStart hook received, row selected. Still to verify by hand: working/finished notifications in a real conversation, close/quit sheets, Resume after exit.

## 2026-09-07 — Ghost rows after closing an unused session
User report: a closed session stayed in the sidebar. Sessions with a transcript are meant to stay (resumable; ADR-013). The bug was placeholder rows (ADR-017) for sessions closed before the first prompt, which never get a transcript and so were never reconciled. Fixed: `SessionStore.removePending` on tab close when the transcript file does not exist.

## 2026-09-07 — Milestone 2, batch 1
Rename, favorite, archive + undo + show-archived, sidebar search, ⌘K quick switcher (ADR-045). New "Session" menu. Lesson: adding a Swift file requires `xcodegen generate` (Makefile `build` does it; a bare `xcodebuild` does not).

## 2026-09-07 — Milestone 2, batch 2
Tab footer: model (launch alias, then transcript `message.model`, shortened e.g. "Opus 5"), git branch (`GitInfo.branch` = `symbolic-ref --short HEAD` then `rev-parse --abbrev-ref`; the former is needed before the first commit), cwd (click to copy), foreground pid. Refreshed on `pwd` actions and SessionStart/Stop/PostModelSwitch/CwdChanged/WorktreeCreate hooks. Verified on screen.

## 2026-09-07 — Milestone 2, batch 3
Preferences window (⌘,): reopen last session on launch (waits for `SessionStore.initialScan`), default model, notification sound, hook trace toggle, Reveal in Finder, copy log command. Keys in `Prefs`. Not relaunched for a screenshot because the user had the app open; build green.

## 2026-09-07 — Milestone 2, batch 4
Notification history (`NotificationStore`, bell in toolbar, ⌘⇧B, 200 entries), per-session mute (`ClinicState.mutedSessions`), StopFailure → error entry. Found and fixed a persistence bug: `[SessionID: T]` encoded as a flat array because `SessionID` was not `CodingKeyRepresentable`; now encodes as an object, with a legacy-array fallback in `ClinicState.init(from:)` (tests cover both). The state file on disk only had empty arrays, so nothing was lost.

## 2026-09-07 — Milestone 2, batch 5
⌘J terminal panel (ADR-046): one shell under the agent surface per tab, `VSplitView`, lazily created, freed with the tab; delegate lookups now match either surface.
Verified on screen. Remaining milestone 2: multiple windows, rebindable shortcuts, opt-in global hook (user decision, revisits ADR-018), signing/Sparkle (waits on Developer ID).

## 2026-09-07 — User feedback round: scope and polish
User: no global hook (ADR-047); Apple developer account added to Xcode (no Developer ID certificate on the machine yet; signing scaffold added: `Local.xcconfig`, `scripts/release.sh`, `make release`); sidebar too cluttered from auto-discovery → Clinic-owned sessions only with import via ⌘K (ADR-048); project icons/decoration/actions (ADR-050); visible tab bar (ADR-049); usage panel wanted (ADR-051, next).
Facts: Claude Code on macOS keeps the OAuth token in the Keychain (`Claude Code-credentials`), not `~/.claude/.credentials.json`; the usage endpoint is `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`, response `limits[] {kind, percent, severity, resets_at, scope.model.display_name}` plus `extra_usage`/`spend` (from Collins `usage.py`).
Implemented ADR-047/048/049/050 in one batch (build green, 29 tests).

## 2026-09-07 — Usage panel and a state race
ADR-051 implemented: `UsageService` reads the Keychain item `Claude Code-credentials` (generic password) via `SecItemCopyMatching`, falls back to `~/.claude/.credentials.json`, fetches `/api/oauth/usage` every 5 min, renders bars (session / weekly all / weekly scoped) + extra-usage credits + reset countdowns; preference to hide. Parsing tolerant, tested (32 core tests).
Bug fixed: `SessionStore.start()` re-read state from the actor after `registerPending` had already registered a new owned session, so the first launch showed "No sessions yet". State now seeds synchronously from `StateStore.initialState`.
First Keychain read from Clinic prompts the user; "Always Allow" expected.
Verified on screen: project header (monogram, count, ⋯ menu), owned session row, tab bar, footer, usage panel prompting for Keychain access. Caveat: ad-hoc signed dev builds get a fresh code identity every rebuild, so the Keychain "Always Allow" does not stick until builds are Developer ID signed; the usage panel can be hidden in Preferences meanwhile.
Signing still needs, from the user: a "Developer ID Application" certificate (Xcode → Settings → Accounts → Manage Certificates → +), the Team ID in `Local.xcconfig`, and `xcrun notarytool store-credentials clinic-notary`.

## 2026-09-07 — Roadmap re-evaluation against Collins
User asked to re-check planned features against https://episode6.github.io/collins/guide/features with project/session management as top priority. Wrote [[Collins Feature Gap]] (full table) and re-cut the Backlog: milestone 3 is now session & project management parity (8 batches), git/PR/composer/editor move to milestone 4+. Awaiting user confirmation of the order.
User chose: milestone 3 = the Collins pages (git → PR → composer → attachments → MCP tools → editor → replay/details → background agents → polish), milestone 4 = management parity. Starting with the git page.

## 2026-09-07 — Milestone 3, batch 1: git page
ADR-052 implemented. Core git layer written by a subagent (GitRepository actor, UnifiedDiff parser + hunk/line patch reconstruction verified against real `git apply`, FSEventsWatcher; 11 tests). UI: GitPage right column per tab (⌘⇧G, footer), DiffView reusable component, GitPageModel. Verified on screen against the repo's own uncommitted changes: status lists, hunk Stage/Discard, commit box, commit history. Found on the way: the usage panel's synchronous Keychain read on the main thread froze the UI while the prompt was up — now off-main. Smoke keys: `-ClinicShellDirectory <path>`, `-ClinicOpenGitPageOnLaunch YES`, `-ClinicShowUsage NO` (avoids the Keychain prompt on dev builds).

## 2026-09-07 — Milestone 3, batch 2: pull request page
ADR-053 implemented. Core by subagent: `PullRequestRef` (pr-link records + prompt URLs), `PullRequest.parse` over `gh pr view --json`, `PullRequestMark` (checks failing > conflicts > changes requested > unanswered comments (bots ignored) > pending > approved), `GitHubService`; `ProcessEnvironment.withToolPaths()` prepends Homebrew to PATH for all subprocesses. gh quirks recorded in the subagent report: merged PRs still report CONFLICTING/DIRTY; rollup mixes CheckRun and StatusContext; reviews use `submittedAt`. UI: PRStore, PRPage (overview/checks/timeline/files), chips, sidebar mark, ⌘⇧P, merge-method pref. Verified on screen with Campfire #1054 (merged). Smoke keys: `-ClinicOpenSessionOnLaunch <id>`, `-ClinicOpenPRPageOnLaunch YES`.
Layout lesson: `HSplitView` with minWidth/idealWidth children overflowed the window (and `layoutPriority` made it worse). Replaced with `RightSplit` (GeometryReader + drag divider, right width clamped to `[320, total − 360]`, persisted in `ClinicRightPaneWidth`). Verified: PR page fits at a 1300 px window.
User feedback: right-column divider hard to grab (1 px line; hit area swallowed by the terminal NSView) → 8 px divider column with a grip; icons too small/ambiguous → footer toggles are labeled (Panel / <branch> / PR #n), state glyphs 10 px with tooltips, project icons 22 px, toolbar "New Session" uses `square.and.pencil`.

## 2026-09-07 — Milestone 3, batch 3: composer, new-chat screen, drafts
ADR-054 implemented. Key fact: libghostty's `text:` binding action writes raw bytes to the pty with escape parsing, so `sendPaste` wraps text in `ESC[200~ … ESC[201~` (bracketed paste) and `pressEnter` submits; verified by a bridge test piping into `cat`. `ClaudeLaunch` gained `prompt` (positional) and `--effort`. ⌘N → new-chat screen (project header, editor, worktree/model/effort, Send / Empty Session), ⌘⇧N → folder picker first. Drafts: `ClinicState.newChatDrafts` shown as pencil rows; `sessionDrafts` restore composer text per session. ⌘. composer docked under the terminal, Send gated on `idle`. Both screens verified on screen (smoke keys `-ClinicNewChatOnLaunch <path>`, `-ClinicOpenComposerOnLaunch YES`). Not yet verified by hand: an actual Send from the composer into a live Claude prompt.

## 2026-09-07 — Composer removed (ADR-055)
User: the embedded terminal is the prompt; the composer and new-chat screen are redundant. Removed both plus drafts; the New Session sheet launches directly again and gained an effort picker. Bridge `sendPaste` and `ClaudeLaunch.prompt` kept for tools/PR page.

## 2026-09-07 — Milestone 3, batch 4: session MCP tools + attachments
ADR-056 implemented. `clinic-hook mcp <sock> <session-id>` is the stdio MCP server (session identity travels in the per-session `--mcp-config` file, no process-tree tricks). Clinic's `MCPServer` answers `tools/list`/`tools/call` on the main actor. Tools: set_session_title, notify_user, show_image (→ attachments panel, ⌘⇧I), read_terminal (`GhosttySurfaceView.visibleText` = `ghostty_surface_read_text` over a viewport selection), run_in_terminal (shell panel; off by default), attach_pr, start_session. Per-tool switches in Preferences → Session tools.
Verified: the CLI's own MCP client called tools/list ~0.8 s after launch; a hand-driven shim conversation set the sidebar title and read the screen. Bug found: the shim exited on stdin EOF before worker threads replied — now waits on a DispatchGroup.
Deferred: show_diff/annotate_diff/highlight_diff (need diff marks), open_in_editor (needs the editor), transcript-image scanning for attachments.
User: right-column resize jittery. Cause: custom split wrote `@AppStorage` on every drag event and relaid out both panes per event. Replaced with `NSSplitView` (`RightSplit` is now an `NSViewRepresentable` hosting the two SwiftUI trees in `NSHostingView`s; environment objects re-injected; min widths via delegate; `autosaveName = "ClinicRightPane"`). Team ID placed in gitignored `Local.xcconfig` (see `Local.xcconfig.example`); the user's `notarytool store-credentials` attempt failed with 401 (app-specific password).

## 2026-09-07 — What a macOS port of Collins would actually cost
User asked, as an aside from Clinic work, how much lift it would take to make Collins itself run on macOS. Investigated against a shallow clone in the session scratchpad (dependency/platform surface only — no implementation copied into Clinic; [[ADR-002 Collins as the Milestone 1 Spec]] permits study).
Findings: the dependency wall upstream cites is gone — Homebrew's `vte3` bottle for arm64 ships `Vte-3.91.typelib` + `libvte-2.91-gtk4.dylib` (formula builds `-Dgtk4=true`), and gtk4/libadwaita/gtksourceview5/pygobject3/gstreamer all have arm64 bottles (64-formula closure). Whether VTE renders and takes input on the GTK4 quartz backend is untested and is the one blocking unknown; the bottle ships a `vte-2.91-gtk4` demo binary that answers it in half a day.
Real Linux couplings are small and contained: `statusicon.py` + `traymodel.py` (1436 lines of hand-rolled StatusNotifierItem over D-Bus — no macOS equivalent, and close-to-hide/badge/unread hang off it), `proctree.py` (188 lines, `/proc`, ~13 call sites in terminal.py/app.py), `SO_PEERCRED` in `mcpserver.py` (→ `LOCAL_PEERPID`), `desktopentry.py`/`openwith.py` (.desktop, xdg-terminals), screen-lock detection over D-Bus, `Gtk.Application.inhibit` for Caffeine. XDG paths degrade harmlessly. Probed `g_file_trash` on this Mac via ctypes: it succeeds but writes the *freedesktop* trash (`~/.local/share/Trash`), not the Finder one — "move to trash" would silently hide transcripts from Finder.
The real cost is the tail: no native menu bar under GTK4 quartz, CSD window controls, ~40 Ctrl-based default bindings, an untested-by-anyone GTK4+VTE+quartz stack (the code already carries Wayland/X11 segfault workarounds), and a `.app` bundle with 64 dylibs + typelibs to codesign and notarize. Estimate given: half a day to spike, 1–2 weeks to "runs degraded on my Mac", +3–6 weeks to bundled/signed/Mac-idiomatic, then permanent ownership of a second platform in a 82k-line app whose CI is ubuntu+xvfb only.
No Clinic code changed.

## 2026-09-07 — VTE-on-quartz spike: it works
Ran the spike rather than guessing. Installed `vte3 pygobject3 adwaita-icon-theme` via Homebrew (GTK 4.22.4, VTE 0.84.1, arm64 bottles) and drove a `Vte.Terminal` from PyGObject on this Mac.
Result: `GdkMacosDisplay` + GSK `GLRenderer`; `spawn_async` opened a real pty (`/bin/sh`); the emulator parsed its output back through `get_text_range_format`; the widget rendered to PNG with correct glyphs, bold-green SGR and reverse video; `grab_focus()` succeeded. **OSC 9;4 progress termprops work on macOS** — feeding `\033]9;4;1;42` made `vte.progress.value` read back 42, so Collins' most-trusted busy signal survives the port. OSC 7 works too (`get_current_directory_uri()` → `file://localhost/private/tmp`), which is the better replacement for the `/proc` cwd read anyway.
The other two unknowns also resolved green: `proc_pidinfo(PROC_PIDVNODEPATHINFO)` reads a same-uid child's cwd with no root and no entitlement (so `proctree.py` ports cleanly), and `LOCAL_PEERPID` + `getpeereid` replace `SO_PEERCRED` for the MCP shim's identity check. One real behavioural difference: `LOCAL_PEERPID` returns ENOTCONN once the peer exits, where Linux's `SO_PEERCRED` keeps answering — it must be read at accept time.
Untestable without a human: real keystrokes through quartz GDK (GTK4 removed synthetic event injection).
Revised estimate: the dependency and syscall risk is gone; what's left is the tail — tray/StatusNotifierItem, Cmd bindings, no native menu bar, CSD window controls, Finder-vs-freedesktop trash, and a signed/notarized `.app` bundle. Relevance to Clinic: none of it changes the ADR-002 plan, but it confirms the two mechanisms Clinic replaced with hooks (`/proc` walking, `SO_PEERCRED`) were portable after all — the reason to prefer Clinic's design is robustness, not platform.

## 2026-09-07 — Milestone 3, batch 5: editor panel
User: editor wanted for quick checks with syntax highlighting; editing a bonus. Mid-batch the user allowed third-party packages → ADR-058 supersedes ADR-023; ADR-057 switched from a home-grown tokenizer to CodeEditApp/CodeEditSourceEditor 0.15.2 (tree-sitter). The subagent writing the core pieces hit the session usage limit; FuzzyMatcher, FileIndex (git ls-files with a walk fallback), `SessionSummary.recentFiles` (Write/Edit/MultiEdit/NotebookEdit tool_use paths) and tests written by hand (76 core tests).
Two bugs found by launching: (1) the main window collapsed to its title bar when the editor pane appeared — nested `NSHostingView`s in `RightSplit` were pushing SwiftUI size constraints to the window; fixed with `sizingOptions = []` on both hosts. (2) SIGABRT with no stderr, found via `/usr/bin/log … HIExceptions`: CodeEdit's `MinimapView.setTheme` raised `NSInvalidArgumentException` on macOS dynamic colours; `EditorThemes` now resolves every colour to sRGB under the current appearance. Build passes `-skipPackagePluginValidation -skipMacroValidation` (SwiftLint plugin). Package pinned with `exactVersion`.
Smoke keys: `-ClinicOpenEditorOnLaunch YES -ClinicOpenFileOnLaunch <abs path>`.
Third bug: the file tree stayed empty because `.task` hung off a `ForEach` with zero rows; replaced with a prebuilt `FileTreeNode` tree rendered by `OutlineGroup`. Verified on screen: tree, Swift highlighting, header with Save/Revert.

## 2026-09-07 — Collins forked; upstream is already porting to macOS
User asked to fork Collins and hand the macOS port to a separate session. Forked to `r0adkll/collins`, cloned to `~/SoftwareProjects/main/collins` (origin = fork, upstream = episode6).
**Discovery that changes the picture: episode6 started the macOS port on 2026-09-05.** Branch `upstream/macos-spike-pr0`, closed spike PR #497, a private spec at `~/specs/collins/macos-homebrew-port.md` on the maintainer's machine with a numbered plan (PR 0 spike → PR 2 AF_UNIX socket paths → PR 3 trash shim → PR 4 real macOS CI), and a `macos-15` CI workflow. **Collins already launches on macOS 15** — sidebar, header bar, usage row, no traceback, with proctree both live and stubbed.
Their spike answers the question I couldn't: typed input echoes in VTE on quartz. It also surfaces one I had missed and which matters most — **kqueue directory monitors do not fire on appends to existing files**, and Collins' sidebar watches `~/.claude/projects/` for exactly that, so live updates are the architectural risk, not the terminal. Also: `Gio.AppInfo.get_all()` returns 0 on macOS (footer apps/open-with is a "never"), GLib has no launchd D-Bus lookup (`gdbusaddress.c` TODO #694472) so `Gio.Application` uniqueness is lost without an explicit `DBUS_SESSION_BUS_ADDRESS`, and pytest is 2996 passed / 40 failed (35 of them `AF_UNIX path too long` under macOS temp dirs).
One correction worth sending upstream: their spike concludes brew's glib is "built without Cocoa … by the same token no Cocoa notification backend". On this machine `otool -L libgio` shows Foundation/CoreFoundation/AppKit/CoreServices linked and `nm` exports `g_osx_app_info_*`, with `GCocoaNotificationBackend` in the binary — so the trash behaviour is explained by their *other* finding (the `HAVE_COCOA` trash branch is GLib main #1161, not 2.88.3), and desktop notifications may be closer to free than their spec assumes.
User chose: get it running locally first, no PRs, and spawn a separate interactive session for it. Wrote `macos-port/NOTES.md` (research + port map) and `macos-port/BRIEF.md` (task, safety rules: `~/.claude` read-only, sandboxed XDG dirs, no trash/archive/worktree actions, no push) into the fork, with the VTE/peer-pid probe scripts and the render PNG. Installed the rest of the runtime stack via brew; all 12 gi namespaces import under `python@3.14`. Launched the porting session in a new Ghostty window (`open -na Ghostty … -e fish -l -c claude …`).
Clinic itself unchanged. Clean-room boundary noted in both handoff docs: porting work stays in the collins repo, never moves code into clinic.

## 2026-09-07 — Milestone 3, batch 6: replay and session details
ADR-059 implemented. `TranscriptTurns` (full read, ≤50 MB, off-main) → turns + stats. Replay is a tab (`Tab.Kind.replay`) with a dormant `/usr/bin/true` surface so `Tab` stays uniform; bubbles, Step/Play/Show all. Details sheet (⌘I / context menu) verified on Campfire session: 662 turns, 270 tool calls, 115M cache-read tokens, $84.53, 10h 11m. Smoke keys: `-ClinicReplayOnLaunch YES`, `-ClinicDetailsOnLaunch YES` with `-ClinicOpenSessionOnLaunch <id>`.
Remaining in milestone 3: MCP servers browser (small), background agents, polish.

## 2026-09-07 — Milestone 3, batch 7: MCP servers browser
ADR-060 implemented: `MCPServersConfig` reads `~/.claude.json` (global + `projects[path].mcpServers`, enabled/disabled lists) and project `.mcp.json`; sheet on ⌘⇧M. Verified on real config (2 global, Campfire project 2 + 1 from .mcp.json). Real args contained a bearer token → `MCPServerEntry.redact` masks bearer tokens, `key=value` secrets and `sk-…` keys in the display.

## 2026-09-07 — Milestone 3, batch 8: background agents
ADR-061 implemented. CLI facts differ from docs: `claude agents --json` reports `kind: "background"` (not `background_agent`) and a waiting detached session as `state: "blocked"` (not `needs_input`); both accepted. First poll must wait for the sidebar's initial scan or nothing can be adopted. Verified via state file that a real `claude --bg` test session (id de9b277b, blocked on a `sleep 90` permission) was adopted; screen capture unavailable (display asleep) so the sidebar glyph, Attach/Stop/Logs/Remove menu and the close sheet's Background button are unverified on screen. The test agent was left running for the user to exercise them.
Milestone 3 remaining: polish (select mode, rebindable shortcuts, multiple windows, caffeine) — then milestone 4 management parity.
Verified on screen after the display woke: the detached `clinic-bg-test` session appeared under its project; clicking it attached (full conversation visible in the tab). Limitation found: `claude attach <id>` takes no `--settings`, so attached tabs receive no hooks; they now show a moon glyph ("attached, state not reported") and count as running for the close confirmation.

## 2026-09-07 — Milestone 4, batch 1: project groups
ADR-062 implemented and verified on screen (window capture by id works even when the user is on another Space: `screencapture -l <wid>`). Manual order via `projectOrder`, folds via `collapsedProjects`, sort via `ClinicSessionSort`, folder paths via `ClinicShowFolderPaths`.

## 2026-09-07 — Milestone 4, batch 2: session lifecycle controls
ADR-063 implemented. Verified by hook trace: Stop → SessionStart then SessionEnd; Fork → SessionStart(source: fork) under a new id, tab rebound, new id owned. Found on the way: `ownedSessions` accumulated placeholder ids from sessions killed before their first prompt (app quit before `removePending`), which hid the clinic project entirely; stale ids are now dropped on scan. Scratch folders prompt for trust on fork/resume (expected, ADR-018). Smoke keys: `-ClinicStopAfterLaunch <s>`, `-ClinicForkOnLaunch <id>`.
Not verified on screen: Open in Ghostty, Open In…, Export as Markdown (all straightforward NSWorkspace/save-panel calls).

## 2026-09-07 — Milestone 4, batch 3: model and effort switching
ADR-064 implemented and verified: `/model sonnet` typed from the footer path, CLI confirmed, chip updated. `PostModelSwitch` payload has no model field. Smoke key `-ClinicSwitchModelAfterLaunch <alias>`.

## 2026-09-07 — Milestone 4, batch 4: repo upkeep
ADR-065 implemented; core worktree ops tested against a real temp repo (list/remove/add/prune, checkout refused while a worktree holds the branch). UI actions (Git Pull, Checkout default, Archive Project, worktree trash/undo) not exercised on screen.

## 2026-09-07 — Milestone 4, batch 5: attention
ADR-066 implemented; card verified on screen (session finished while a shell tab was selected → card with project icon, row unread dot, bell badge). Update check unverified (no releases exist yet). Smoke key `-ClinicSelectTabAfterLaunch <index>`.

## 2026-09-07 — Milestone 4, batch 6: menu bar status item
ADR-067 implemented. The item is created and updates (log: `bell.badge.fill unread=1`, frame x=970 w=50 in the menu bar), but on this MacBook the menu bar is full and new items land under the notch, where macOS hides them. It will show once an item is removed or on an external display. Not a code defect.

## 2026-09-07 — Milestone 4, batch 7: Chats
ADR-068 implemented and verified: pinned Chats project with bubble icon; chat runs in `~/Library/Application Support/Clinic/Chats` (trust prompt once). Smoke key `-ClinicNewChatOnLaunch YES`.

## 2026-09-07 — Milestone 4, batch 8: Keep Running and quit behaviour
ADR-069 implemented; the quit sheet (Quit / Background All / Hide Window / Cancel) verified on screen via an AppleScript quit request. Milestone 4 complete.
Remaining before 0.1.0: hand checks, Developer ID certificate + notarization, Sparkle. Milestone 3 polish group (select mode, rebindable shortcuts, multiple windows, caffeine) still open.

## 2026-09-07 — Usage panel consent (ADR-070)
User: never prompt for credentials by default. Panel now starts disconnected with Connect (also in the collapsed header) and Preferences has Connect/Disconnect; verified by log that launch performs no Keychain read and no fetch. Dev-build Keychain prompt annoyance is gone.

## 2026-09-07 — Bug: terminal vanished when closing the git/PR page
User report (reopening the page brought it back). Diagnosed with lifecycle logging: SwiftUI created a transient `SurfaceContainer` inside the dying `RightSplit` hosting view during teardown; it stole the surface (single-owner guard did not help because the thief was created last) and was torn down with the surface inside → surface orphaned; reopening created a fresh container that re-adopted it. Fix: surfaces are never re-parented by SwiftUI any more — `Tab.contentView` is a persistent `TabContentView` (`NSSplitView` tree) and `TabContentRepresentable` only syncs panel/page. `RightSplit` and `SurfaceContainer` deleted. Verified: close page → terminal stays; panel + page together lay out correctly.

## 2026-09-07 — New-session screen (ADR-071)
User: starting a session should be a screen in the content area (prompt, model, effort, worktree/branch), not a sheet; the docked composer stays out. Restored and extended the earlier screen: `NewSessionScreen` + `NewSessionDraft` (in-memory per project), `ClaudeLaunch.worktreeName` → `-w <name>`. Verified on screen. Smoke key `-ClinicNewSessionScreenOnLaunch <path>`.
Release: Developer ID certificate and `clinic-notary` profile present; first archive failed linking x86_64 (native xcframework) → `ARCHS = arm64`; archive + Developer ID export succeeded; notarization submitted.

## 2026-09-08 — First-prompt bug and first notarized build
User hit `Error: Invalid MCP configuration: MCP config file not found: …/clinic/Where are we at…`: the CLI's `--mcp-config <configs...>` is variadic and swallowed the positional prompt. `ClaudeLaunch.arguments` now emits the prompt first (tests updated, 86 green).
Release: `make release` produced `build/release/Clinic-0.1.0.zip` — archive + Developer ID export succeeded, notarization **Accepted** (id 17e12dac…), stapled, `spctl` says "Notarized Developer ID". Apple Silicon only (ADR-010 note). Not yet tagged.

## 2026-09-08 — Milestone 3 polish group: windows, shortcuts, select mode, caffeine
ADR-072 (multiple windows), ADR-073 (rebindable shortcuts), ADR-074 (sidebar multi-select), ADR-075 (caffeine) implemented in one batch; 90 core tests green (4 new for KeyChord).
Design: one `TabStore`, `Tab.windowId` + per-window `WindowState` (selection, draft, select mode); `tabs.selectedTab`/`editingDraft` forward to the active (last key) window. The content area is now one AppKit `TerminalStackView` per window that adds/hides each tab's persistent `TabContentView` and removes only its own subviews, so moving a tab between windows is a plain re-parent (`TabContentRepresentable` deleted). Closing a non-last window re-homes its tabs. `KeyChord`/`ShortcutOverrides` in ClinicCore (grammar `cmd+shift+n`), `ShortcutAction` + `KeyBindings` store + AppKit recorder in the app; every menu chord reads the store. Multi-select: `List(selection: Set<SidebarItem>)`, plain click still opens, ⌘/⇧-click or select mode builds the bulk set; `contextMenu(forSelectionType:)` serves the single/bulk menus. Caffeine: `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`.
Bug found and fixed on the way: with `WindowGroup(id: "main", for: UUID.self)` the app launched with **no window at all** whenever AppKit saved state from the old scene shape existed (`restoreWindowWithIdentifier` accepted, then nothing presented); `.restorationBehavior(.disabled)` and `.defaultLaunchBehavior(.presented)` did not help. Bisected with concurrent flagged instances; fix: `applicationWillFinishLaunching` sets `ApplePersistenceIgnoreState`, windows are `isRestorable = false`, the primary window keeps its frame via `setFrameAutosaveName("ClinicMainWindow")` (ADR-042 unchanged in effect).
Testing lesson (costly): a second Clinic instance unlinks and rebinds the *live* instance's `hook.sock`/`mcp.sock` — the hosting Clinic of this session lost hooks/MCP until relaunch. Added `CLINIC_APP_SUPPORT` (all App Support lookups go through `ClinicPaths`); smoke instances now run with `open -n -g --env CLINIC_APP_SUPPORT=~/Library/Caches/clinic-smoke -a build/…/Clinic.app --args …` (a short path: unix sockets cap at 103 bytes; windows launched via `nohup` from the tool sandbox never reach the window server). `screencapture -l <wid>` needs the sandbox off; window ids from a tiny CGWindowList lister.
Verified on screen: move tab to new window (cascaded +28 px, live terminal), close secondary → tab re-homes, select mode checkboxes + action bar, Shortcuts preferences tab, `pmset -g assertions` shows the caffeine assertion. Not verified by hand: the recorder's conflict message, Move to Window ▸ submenu, bulk archive.
Smoke keys: `-ClinicMoveToNewWindowAfterLaunch <s>`, `-ClinicCloseSecondaryAfterLaunch <s>`, `-ClinicSelectModeOnLaunch YES`, `-ClinicCaffeineOnLaunch YES`, `-ClinicPreferencesOnLaunch YES -ClinicPreferencesTab shortcuts`.

## 2026-09-08 — New-session screen layout pass
User: centre the project logo, name and path in a column above the prompt; halve the prompt box; put model, effort and worktree on one row with a switch for worktree. `NewSessionScreen` now has a centred header `VStack` (icon 48 pt, name at `.largeTitle`) with the discard ✕ as a top-trailing overlay on the *content area*, not the header, a `TextEditor` at 80–180 pt (was 160–360), and one `HStack(spacing: 24)` holding both pickers (`.fixedSize`), the `Worktree` toggle (`.switch`) and the branch field. No ADR change: [[ADR-071 New Session Screen]] specifies the controls, not their arrangement. The whole block is centred in the content area (outer frame alignment `.center`) rather than pinned to the top. Verified on screen with `-ClinicNewSessionScreenOnLaunch <path>` on a `CLINIC_APP_SUPPORT` smoke instance.

## 2026-09-08 — Project icon generation (ADR-076)
User: "add the ability to generate project icons". ADR-050 had ruled headless generation out, so [[ADR-076 Project Icon Generation]] amends that one clause (ADR-050's menu and hover actions stand) and the design tree + backlog now point at it. User chose repo storage (`<project>/.clinic/icon.svg`, ADR-050's existing lookup path) over Application Support, and a preview sheet over a one-shot action.
Implementation: `ProjectIconGenerator` in ClinicCore runs `claude "<prompt>" -p --model sonnet --allowedTools Read,Glob,Grep --permission-mode dontAsk --no-session-persistence --strict-mcp-config` with the project as cwd (prompt first, same variadic-swallow trap as `ClaudeLaunch`), extracts the `<svg>` from fenced or bare output, rejects script/foreignObject/image/href/DOCTYPE/entity/event-handler/>64 KB, repairs a missing `xmlns`, and writes only `.clinic/icon.svg`. `ProcessBox` carries cancellation and the 180 s timeout onto the child process. `GenerateIconSheet` has the hint field, Generate/Regenerate/Stop, 64 pt + 22 pt previews on light and dark chips (plus the current icon when there is one) and Use; `ProjectIconCache` is `@Observable` with a `revision` counter and per-path `invalidate`, so every `ProjectIcon` redraws after Use. Project menu gained *Generate Icon…* and *Remove Generated Icon*.
Facts worth keeping: `NSImage` renders SVG natively (`_NSSVGImageRep`), from a file **and** from `Data`, even without an `xmlns`; a headless icon run costs ~8-20 s on sonnet; `--no-session-persistence` keeps the run out of `~/.claude/projects`; stdin must be `/dev/null` or the CLI waits 3 s for piped input.
Verified on screen (smoke instance, `CLINIC_APP_SUPPORT`): sheet with light/dark previews for this repo; then on a scratch project ("Fern", a plant-watering README) `-ClinicGenerateIconAutorun use` wrote a green frond + droplet SVG and the new-session screen's 48 pt icon swapped from the monogram to it without a relaunch. Per-window `screencapture -l` produced stale composited layers for the sheet — full-display `screencapture -D 1` was the reliable capture. 97 core tests green (7 new). Not verified by hand: the two new menu items, Stop mid-run, and a rejected-SVG error state.
Smoke keys: `-ClinicGenerateIconOnLaunch <path>`, `-ClinicGenerateIconAutorun generate|use`.

## 2026-09-08 — Sidebar polish: persistent projects, added-order, row legibility (ADR-077)
User: "Projects that are added should be persistent. When I close a lone session (or archive) sometimes the project disappears. The ordering doesn't seem to stay consistent (should be when the project was added). It shouldn't say 'Sessions'. The sizing and spacing could use some refinement. When a session is selected, the hover actions are hard to read due to coloring."

Root cause of the disappearing project: sidebar membership was derived from *live* sessions plus `ClinicState.addedProjects`, and only the "+" folder picker ever wrote that array. A project first seen through ⌘N was therefore only as durable as its sessions — archiving the last one (or `removePending` dropping a session whose transcript never appeared) took the whole group with it, contradicting [[ADR-030 Project Grouping]].

[[ADR-077 Persistent Projects and Sidebar Polish]] (supersedes parts of ADR-040, ADR-050, ADR-062):
- `ClinicState.projectsAddedAt: [String: Date]` replaces `addedProjects`. `registerProject`/`unregisterProject` are on the state struct; every entry point registers (folder picker, `registerPending`, `adopt`). Legacy state migrates in `init(from:)` — picked folders keep their relative order at epoch 0…n, everything else takes its first owned session's `addedAt` — and the old key stops being written.
- `ProjectRoster.paths(_:)` in ClinicCore is the whole membership + ordering rule as a pure function: registered ∪ has-a-visible-session, minus removed; pinned (Chats) → `projectOrder` (drag) → the rest by registration date ascending, ties on path. `SessionStore.rebuildProjects` is now four lines over it. 10 new tests (107 green).
- Archive Project *unregisters* rather than removing, so unarchiving a session brings the project back at its old position (the roster falls back to its earliest session date); Remove Project does both.
- Sidebar toolbar: no caption, right-aligned `ToolbarIcon` row (secondary → primary on hover, accent while select mode is on).
- Session row: hover actions moved from "replace the timestamp" to trailing icon buttons (`RowAction`) with **no colour of their own**. That was the legibility bug — `.foregroundStyle(Color.accentColor)` on an accent-filled selected row. Plain-styled labels inherit the row's selection foreground instead. The row also no longer reflows on hover.
- Header: 18 pt icon, count pill only while collapsed, `+`/`⋯` at opacity 0 until hover but always occupying their space.

Verified on a `CLINIC_APP_SUPPORT=~/Library/Caches/clinic-smoke` instance seeded with a copy of the live `state.json`: migration produced the expected `projectsAddedAt` and dropped `addedProjects`; order (livewire, clinic, Campfire) survived a relaunch; star and archive hover actions fire and persist; archiving both of `clinic`'s sessions left the project sitting between livewire and Campfire.

Testing notes: `CGWarpMouseCursorPosition` + a synthetic `mouseMoved` is enough to drive SwiftUI `onHover` (no accessibility grant needed), but the live Clinic hosting the session keeps stealing focus — activate the smoke pid via `NSRunningApplication(processIdentifier:)?.activate` **inside the same script** that clicks and shells out to `screencapture -D 1`, or the capture lands on the wrong app. Screen is 1800×1169 pt at 2×, so screenshot pixel ÷ 2 = warp point. `sips --cropOffset` is (top, left) and `-c` is (height, width).

Follow-up pass the same day (ADR-077 metrics amended): count pill shows expanded as well as collapsed; 6 pt between the header's hover actions and the sidebar edge; 8 pt `contentMargins(.top, for: .scrollContent)` above the first project; a `NewSessionPlaceholderRow` under any project with no sessions ("New Chat" in Chats, "New Session" elsewhere — the project menu's wording); add-project is `folder.badge.plus`; project icon 18 → 22 pt and the name `.subheadline` → `.body` semibold. Verified on a smoke instance.

User: "The sidebar is missing the persistent Chat project for non-project-affiliated chats." ADR-068 had deliberately hidden Chats until it had a session, which the persistent-projects pass made inconsistent — an always-there scratch group is the point. ADR-077 now supersedes that clause too: `ProjectRoster.Inputs.pinnedFirst` forces membership (always listed, first, immune to `removed`) rather than only ordering, so Chats shows with its speech-bubble icon and the "+ New Chat" placeholder from a cold start; *Remove Project* is dropped from its menu. 108 core tests green.

User: the new gap above the first project "pops into existence when I scroll the list at all". `.contentMargins(.top, 8, for: .scrollContent)` on a `List(.sidebar)` is applied on a later layout pass, so it is absent on the first paint and appears once the scroll view settles. A leading spacer row is not the fix either — a `Color.clear.frame(height: 6)` row takes the sidebar's minimum row height (~27 pt). Landed on `Divider().padding(.bottom, 8)` in the sidebar `VStack`: the gap is plain stack layout outside the scroll view, so it is there on the first frame and scrolling cannot move it. ADR-077's metrics line updated.

User: indent sessions and the placeholder so the sidebar reads like a tree. `SidebarMetrics.childIndent` = 28 pt, derived rather than eyeballed: the header puts its name at 12 pt chevron + 6 + 22 pt icon + 6 = 46, a child row puts its title at 10 pt glyph + 8 = 18, so 46 − 18 = 28 aligns the two text columns exactly and leaves the chevron alone in the left margin. Applied as `.padding(.leading, …)` inside the row content, so selection and hover fills still span the full width. Favorites rows share it — the session-row column stays uniform down the whole sidebar.

User: the indent was "too aggressive", the child title did not line up with the project name and the glyph/'+' did not line up with the project icon. The first attempt (a flat 28 pt indent on a child whose glyph column is only 10 pt wide) could satisfy at most one of those two alignments at a time — it aligned the text and left the glyph floating between the header's chevron and icon. Fix: children reuse the header's columns instead of choosing an indent — `childIndent` 18 (chevron 12 + gap 6), `glyphColumn` 22 (the icon's width), `glyphGap` 6, with the leading glyph wrapped in a `Group` frame so every variant (state dot, `moon.zzz`, attention badge, placeholder `+`) centres in the icon's column. Text then lands at 12+6+22+6 = 46 pt for both rows by construction. Verified by decoding the screenshot and comparing pixel columns rather than by eye: header text 117 px, child text 121 px at 2× — a ~2 pt residual that is glyph side bearing (semibold "C" vs regular "N"/"S"), not layout.

Third pass on the indent, user's call: `childIndent` 18 → 12, i.e. the chevron's width and nothing more (the 6 pt gap after the chevron is not indented). The shared 22 pt glyph column stays, so the leading glyphs still share one column; children now sit one chevron in from the project rather than aligned under its name. Lesson for this sidebar: the derived "correct" alignment (18, both columns matching) read as too deep — the shallower hanging indent wins on feel.

Fourth pass: `childIndent` 12 → 6. The indent settled far shallower than the geometry suggested — 28 (title-aligned) → 18 (both columns aligned) → 12 (chevron) → 6. In a ~230 pt sidebar where the header already carries an icon and the child a small glyph, the icon/glyph contrast alone reads as nesting; a real outline indent just eats title width. Don't re-derive this from column maths next time.

Indentation reverted entirely at the user's call ("not happy, reset and remove this past effort"). `SidebarMetrics`, the shared 22 pt glyph column and every `.padding(.leading, …)` are gone; `SessionRow` and `NewSessionPlaceholderRow` are back to `HStack(spacing: 8)` with 10 pt leading glyphs, exactly as before the tree-view attempt. Four values were tried (28 → 18 → 12 → 6) and none felt right: **do not propose indenting sidebar sessions under their project again.** In a ~230 pt sidebar the project's 22 pt icon against a session's 10 pt dot already carries the hierarchy, and any indent just eats title width. ADR-077 now records the rejection so the option is closed rather than re-litigated.

## 2026-09-08 — "Open In" app icons and the footer quick action (ADR-078)

User: render the app image for each choice in the session menu's "Open In", and add a quick action (menu/toolbar) that opens the current session in a chosen app, with a dropdown of app images for changing the default.

`OpenInApps` (new, `Sources/Clinic/OpenInApps.swift`) is now the single source of Open In destinations: Finder, Ghostty (when its binary resolves) and the ADR-063 editors Launch Services knows about, each with its bundle path so the icon can be read and cached per size; re-resolved when older than 60 s. `OpenInMenu` (sidebar session menu, project menu) is a thin wrapper over it, and picking an entry anywhere sets the default (`UserDefaults` `ClinicOpenInDefault`). The quick action is a split chip in the tab footer beside the working directory: icon + app name opens the cwd there, the chevron shows the icon list.

The quick action started in the window toolbar and had to move. On macOS 26 a colour app icon in a `ToolbarItem` menu label renders **desaturated** — verified by screenshot, and `.renderingMode(.original)` does not help; SwiftUI also drops sibling views in that label (a red `Circle()` probe next to the image never appeared), so the toolbar item is taking only the image. Menus are fine: an `NSHostingMenu` probe of `Label { Text } icon: { Image(nsImage:) }` shows Finder/Ghostty/Xcode icons in full colour, same as a hand-built `NSMenu`. Rule of thumb for this app: **colour icons belong in menus and the footer, never in an NSToolbar item.**

Testing notes: `-ClinicOpenShellOnLaunch YES` on a `CLINIC_APP_SUPPORT=~/Library/Caches/clinic-smoke` instance gives a tab (and therefore a footer) from a cold start with no state to seed. `NSHostingMenu(rootView:).popUp(positioning:at:in:)` is a cheap way to screenshot what a SwiftUI menu actually renders without needing accessibility permission to click one open.

Follow-up: user prefers the toolbar placement on sight and wants to try it live, so the toolbar item is back *alongside* the footer chip — both ship until the call is made, ADR-078's placement clause now records the trial rather than the footer-only decision. The toolbar icon is still desaturated (VS Code renders as a grey silhouette); that is the thing to judge.

Placement settled: **toolbar**, footer chip deleted. User: "changing the program to open shouldn't attempt to open it" — so the dropdown became a picker (`Section("Open with")` + `Toggle` rows, which `NSHostingMenu` renders as a checked list with the colour icons intact) that only rebinds `ClinicOpenInDefault`, and the button beside it is what opens. The converse now holds too: the sidebar/project "Open In" submenus open without silently rebinding that default, so neither control has a hidden side effect. ADR-078 amended from "on trial" to the decision.

## 2026-09-08 — The right panel becomes a tab strip (ADR-079)

User: the right split panel should be generic with tab support — clicking git, prs, files, terminal or attachments adds a tab for that view; the footer quick actions stay but control the panel's visibility and whether their tab exists; clicking a type that is already open just fronts it.

`SidePanel` + `PanelPane` (new `Sources/Clinic/SidePanel.swift`) replace `Tab.rightPane` / `gitPage` / `editor` / `panelSurface`: an ordered strip of panes, one per kind (`terminal`, `git`, `files`, `attachments`, `pr(ref)` — PRs keyed by ref so each gets its own), one selected, plus a visibility flag. Every entry point goes through `TabStore.showPane` (front it, or hide the panel when it is already front) or `revealPane` (never hides — what the MCP tools use). `Tab.panelSurface` survives as a computed lookup of the terminal pane, so the ghostty delegate paths (`surfaceRequestedClose`, `surfaceChildExited`, `tab(forSurface:)`) were untouched.

The shell moved from below the agent surface into the panel, so `TabContentView` lost its vertical `NSSplitView` and the `ClinicPanelSplit` autosave. `SidePanelHostView` is a plain AppKit container: a 30 pt `NSHostingView` strip on top, and below it one page host plus a parked `SurfaceHostView` for the shell — switching panes swaps `rootView`/`isHidden` and never re-parents a libghostty surface. Panes that are not on screen stop their git watcher (`SidePanel.syncWatchers` off `didSet` on `selectedId`/`isVisible`), which is why the watcher bookkeeping vanished from the toggles.

Footer chips now carry three states (filled = on screen, outlined = open behind, plain = closed); `FooterToggle` grew an `open` flag and `PRChip` the same. The five toggles moved out of the Tabs menu into a new **Panel** menu with Next/Previous/Close Panel Tab (⌘⌃] / ⌘⌃[ / ⌘⌃W) and into a "Panel" section of the shortcut editor; chords are unchanged, and `ShortcutAction` raw values are, so existing overrides survive.

Smoke tested on the `clinic-smoke` instance: `-ClinicOpenGitPageOnLaunch` alone (one chip, footer accented), git + panel + editor (three chips, editor fronting widened the panel to its 520 min, the two behind showing the outlined footer state), panel-only (a live shell prompt rendering inside the right column), and `-ClinicToggleGitPageAfter 4` to confirm the terminal still fills the width when the panel hides — the ab0e12d regression did not come back.

Layout lesson from the same batch: inside `SidePanelHostView` the page `NSHostingView` was first given only a frame (set from `layout()`), and the editor collapsed to its fitting size in the bottom-left corner of the panel — an `NSHostingView` keeps `translatesAutoresizingMaskIntoConstraints = false`, so a hand-set frame is simply discarded. Everything in that container is pinned with constraints now (strip 30 pt at the top, content below it, page and shell host pinned to the content's four edges). The old code got away with frames only because the split view constrained the page for it.

Same day, after the user tried the build:

- **Blank panel on first show.** Opening a pane from the footer added `SidePanelHostView` to the split view at zero width and left it there until a divider drag forced a layout pass, so the panel came up empty. `setPanel` now adds the view, applies the content, then calls `layoutSubtreeIfNeeded()` and sets the divider synchronously when the window already has a width (the async placement stays as the cold-start fallback). Same class of bug as the editor collapsing to its fitting size earlier: hosting views need a real layout pass, not just a frame.
- **The quick actions stopped being toggles** (user's call): a footer chip or its shortcut now only *opens* — front the pane, show the panel if hidden, never hide. `showPane` and the old `revealPane` collapsed into one method, so the MCP tools take the same path.
- **Hiding got its own always-present control**: a chevron pinned to the trailing edge of the session tab bar (accent-tinted while the panel is open), plus `Show / Hide Panel` (⌘⌥J) in the Panel menu and the strip's own chevron. `SidePanel.close` no longer flips `isVisible`, so visibility and content are independent.
- **Empty state**: the panel open with no tabs shows "Nothing open here" with a button per available view, the same list the `+` menu offers. Add affordances use the kind's plain name ("Git"); open chips and footer chips keep the live title (the branch, the image count).
- Debug flag `-ClinicToggleGitPageAfter` (meaningless now that the toggles do not toggle) was replaced by `-ClinicCyclePanelAfter <seconds>`, which hides and re-shows the panel from a settled window — the exact path the blank-panel bug needed.

Third round on the panel, same day:

- The panel strip's own show/hide chevron is gone — the session tab bar's chevron is the single control — and the strip's chips now use `TabChip`'s metrics (callout title, caption icon, 10/4 padding, 220 pt cap, 5 pt strip padding) with the strip at 34 pt, so the two tab bars read as one control.
- **The editor pane rendering as a ~200 pt strip along the bottom of the panel was not the panel's layout at all.** Frame logging showed the hosting view at the full 520×976 and a `Color.red` probe filled the panel, so the host was fine; `EditorPanel`'s `HSplitView` was collapsing to its children's ideal height, which is small only when no file is open — every earlier smoke run passed `-ClinicOpenFileOnLaunch`, so the code editor's large ideal height hid it. Both halves now carry `maxHeight: .infinity`. Lesson: probe with a background colour before rearranging AppKit containers; two of my attempted fixes (flipping the container, `sizingOptions`) were aimed at the wrong layer and were reverted.

Panel width is now persisted. Hiding the panel removes it from the `NSSplitView`, so the split view's `ClinicRightPane` autosave was recording a one-subview layout and every re-show fell back to the 480 pt default. `TabContentView` keeps the width itself: `splitViewDidResizeSubviews` records the panel's width (ignoring anything under 200 pt, which is only the transient sizes a freshly added arranged subview passes through), `UserDefaults` `ClinicPanelWidth` holds it — one width for every tab and window — and showing the panel opens the divider to `max(pane minimum, saved width)`. Fronting a wider pane (the editor's 520) therefore raises the remembered width rather than snapping back. Verified with `-ClinicPanelWidth 700` plus `-ClinicCyclePanelAfter`: the panel comes back at 700 after a hide/show, and a run with the editor pane left `ClinicPanelWidth = 520` on disk after the app quit.

The width still came back wrong, and my first test had hidden why: pinning `-ClinicPanelWidth 700` puts the value in the *argument* domain, which shadows every read, so the restore looked right while the recording path was broken. The real fault: `addArrangedSubview` makes the split view hand the new panel a width of its own (roughly half the window) and post `splitViewDidResizeSubviews` **before** we restore the divider, so that interim width was recorded over the user's and then restored. `TabContentView` now holds an `isAdjusting` flag across install-and-position (including `openDividerWhenSized`, which retries until the window has a width at launch), and `rememberWidth` ignores anything recorded while it is set.

New smoke hook because the tests cannot drag a divider: `-ClinicDragPanelTo <points>` calls `TabContentView.setPanelWidth` from the `-ClinicCyclePanelAfter` task, just before the hide/show. Verified end to end without pinning the default: drag to 640 → hide → show → 640; drag to 380 → quit → relaunch → 380; drag to 600 → 600 on disk and on screen. Lesson: never verify a persistence path with a value supplied through the argument domain.


## 2026-09-08 — The git page becomes a Diff panel (ADR-080), step 1

User: *"I don't think a generic GIT interface is very useful in the context of this project. I'm
thinking more of a 'Diff' panel where we can scroll through the diffs of different contexts related
to our current session — the last/current turn, unstaged/staged changes, the branch by commit."*
Right call: a git client is a commodity and the terminal is two keystrokes away, while "what did
this agent just change?" is a question only Clinic can answer — it has the session model, the turn
machine (ADR-026) and the hook stream (ADR-027), and the git page used none of them.

Answers taken before writing the ADR: **fully read-only** (no staging, no commit box), **continuous
scroll plus a file rail** rather than list-then-detail, and **all four scopes** in the first cut
(turn / session / working tree / branch).

The mechanism was settled by measurement before it was written down. A turn is not a git object, so
turn diffs need the tree captured at each boundary — without writing to the user's repo. Tried in a
throwaway repo first:

```
GIT_OBJECT_DIRECTORY=<clinic>/snapshots/<key>/objects
GIT_ALTERNATE_OBJECT_DIRECTORIES=<repo>/.git/objects     # absolute, or read-tree fails
GIT_INDEX_FILE=<clinic>/snapshots/<key>/index
  git add -A . && git write-tree
```

45 ms cold on this repo, 22 ms with a warm index, **zero objects added to `.git`**, untracked files
included, `.gitignore` honoured. The first attempt failed with `fatal: failed to unpack tree object
HEAD` purely because `git rev-parse --git-path objects` hands back a *relative* path and the
alternates variable needs an absolute one — worth remembering, the error names the wrong thing.

Consequences that fell out of the mechanism rather than being designed: commits, amends and rebases
*inside* a turn stop mattering (a tree pair states the net change regardless), and no new hooks are
needed — SessionStart/UserPromptSubmit/Stop are already installed, which is the whole reason this
is cheap. `read-tree HEAD` is deliberately **not** run per snapshot: the scratch index is kept
between calls for its stat cache, and it only ever needs to describe the worktree, never HEAD.

ADR-080 written, ADR-052 marked superseded with a pointer, Design Tree and Backlog updated (new
milestone 5). Amended one clause mid-session: ADR-080 first said `GitRepository` loses `apply` *and*
`commit`; `commit` is what every `GitTests` fixture is built from, so only `apply` goes.

Step 1 (core) built and tested: `GitObjectScratch` + `TurnSnapshot` + `SessionSnapshots`
(`Git/TurnSnapshot.swift`), a `SnapshotStore` actor (`Git/SnapshotStore.swift`), and
`writeSnapshotTree` / `tree(of:)` / `diff(from:to:scratch:)` / `diff(from:toWorktree:)` on
`GitRepository`. `GitProcess.run` gained an environment overlay to carry the three variables.

One actor for every repo, not one per repo: a snapshot is `git add -A` against a shared index, so
two at once would corrupt it, and serialising across repos costs nothing at 20–45 ms. An in-flight
turn (no `headTree`) diffs its base against a fresh snapshot of the live worktree, so "current turn"
and "session" reuse exactly one code path. A `UserPromptSubmit` arriving while a turn is still open
closes the old one where it stood — interrupts otherwise leave a turn in flight forever.

13 new tests in `SnapshotTests.swift`, incl. the two that matter most: the repo's object count is
unchanged by a snapshot and the user's index still reads unstaged, and trees written by an earlier
`SnapshotStore` instance still resolve. Full suite 121/121.

Next: hook wiring (`HookEvent.prompt`, the four events, retention sweep, Diagnostics readout), then
`DiffPanelModel`, then `DiffScrollView` + rail, then the `.git` → `.diff` pane rename.

Step 2 (hook wiring) same day. `HookEvent` gained `prompt`; `SnapshotService` (`Sources/Clinic`)
owns the store and drives it from `TabStore.handle(hookEvent:)`, placed **before** the SessionEnd
close path so a closing session still gets its last turn sealed. `CwdChanged` / `WorktreeCreate`
call `forget(session:)`, which is what makes "a change of repo root starts a new lineage" true in
the app and not just in the store.

Two design corrections while wiring:

- **The routing rules moved into ClinicCore as `SnapshotTrigger(event:)`** — which events matter,
  and the rule that a `compact`/`clear` SessionStart is not a new attach. In the app target they
  would have been untestable; as a pure initialiser they are five tests. An unlabelled SessionStart
  counts as a startup. `SnapshotStore.record(_:session:repoRoot:at:)` is now the single entry point.
- **Events are pumped through one `AsyncStream`, not a Task per event.** `beginTurn` must never
  overtake the `endTurn` before it, and two snapshots of one repo would fight over the scratch
  index. Also: no `deinit` teardown — a `deinit` cannot touch main-actor state, and dropping the
  continuation finishes the stream anyway.

Preferences → Diagnostics shows the snapshot store's size with a Clear button (`SnapshotService` is
now in the Settings environment); retention sweeps 10 s after launch, keeping the repos of sessions
this launch has resolved whatever their age.

**Verified `prompt` is really in the payload** rather than trusting the docs: a `UserPromptSubmit`
hook that writes stdin to a file and `exit 2` blocks the prompt, so the payload is captured with no
model call. `UserPromptSubmit` carries exactly `cwd`, `hook_event_name`, `permission_mode`,
`prompt`, `prompt_id`, `session_id`, `transcript_path`. The Research note's "common fields" line had
omitted `prompt`; corrected there. `prompt_id` is the handle the deferred turn → Replay link wants.

126/126 core tests, app builds. Note `make build` needs `-skipPackagePluginValidation
-skipMacroValidation` (SwiftLint plugin), which plain `xcodebuild` does not pass.

Next: `DiffPanelModel` (the scope enum), then `DiffScrollView` + rail, then `.git` → `.diff`.

Steps 3–5 (model, view, rename) same day; the panel is now real. `DiffPanelModel` replaces
`GitPageModel`: a `Scope` enum (turn / session / workingTree / branch) with each scope's
sub-selection stored *beside* it, not inside, so switching away and back lands where you were.
`currentDiff(_:)` is the one place a scope becomes a pair of trees. `GitPage.swift` and
`GitPageModel.swift` are gone; `PanelPane.Kind.git` → `.diff` ("Diff", `plus.forwardslash.minus`),
`toggleGitPage` → `toggleDiffPanel`. `ShortcutAction.toggleDiffPage` keeps the raw value
`"toggleGitPage"`, so ⌘⇧G overrides on disk survive the rename ([[ADR-073 Rebindable Shortcuts]]).

Reuse that fell out of the snapshot machinery: **Working tree → All changes is HEAD's tree diffed
against a fresh snapshot**, which gets untracked files and deletions in one pass instead of stitching
`diff` + `diff --cached` + a `--no-index` walk. Unstaged and Staged still use `diffAll(staged:)`.
New in `GitRepository`: `branchBaseRef()` (factored out of `commits()`), `diff(branchFrom:to:)` for
`base...HEAD`, `diff(commit:)` (`-m --first-parent`, or a merge commit shows a header and nothing
else), and `stat(from:to:scratch:)` → `DiffStat` from `--numstat`, which is what makes `+n −n` per
turn in the menu affordable. `GitRepository.root` is now `nonisolated` — it is an immutable Sendable
`let`, and every caller wanted it for cache keys without hopping onto the actor.

Two SwiftUI layout lessons, both found by looking at the screen rather than by reasoning:

- **Row highlights stopped at the longest line.** Inside a horizontal `ScrollView`,
  `maxWidth: .infinity` resolves to the *content* width. Fix: measure the viewport with
  `onGeometryChange` and give the stack `minWidth: viewport`. The first attempt did nothing because
  `.fixedSize(horizontal: true)` was still on the stack — fixedSize makes a view ignore the proposed
  width, so the frame widened while the children stayed put. Removing it was the actual fix; each
  line's own `Text` is already fixed-size, which is what gives the stack its content width.
- The branch and ahead/behind moved into the Branch scope's control instead of their own header
  field: 380 pt has no room for a third row, and the pane chip and footer already name the branch.
  ADR-080 amended for both.

Smoke tested on a scratch repo (staged, unstaged, untracked, deleted, a 299-line file, one commit on
a feature branch) with new keys `-ClinicDiffScope <scope>`, `-ClinicPromptOnLaunch <text>`, and
`-ClinicOpenDiffPanelOnLaunch` lifted out of the `ClinicOpenShellOnLaunch` block so it applies to a
real session too. Working tree and Branch scopes verified by screenshot; then a **real haiku session
started from Clinic** wrote a real turn to disk (prompt text, base tree, head tree, sealed on Stop)
and the Turn scope rendered exactly the one line the agent added — isolated from the three unrelated
dirty files in the same repo, which is the entire point of the feature.

Smoke-testing hazard worth remembering: the live app and the smoke instance are the same binary, so
`pkill -f Clinic.app/Contents/MacOS/Clinic` would take down the running app along with the test one,
and `open <path>` activates the *live* instance rather than the smoke one. Kill smoke instances by
pid (`ps -eo pid,command | grep '[C]linic.app'` shows their launch args) and let them activate
themselves on launch.

129/129 core tests (13 snapshot + 8 for the hook routing, branch/commit scopes and numstat), app
builds clean. Remaining from ADR-080: nothing blocking — deferred items are the reviewed-mark on
turns, the turn → Replay link, and `show_diff` / `annotate_diff`.

Later 2026-09-08 — the panel chugged on large diffs, and wanted syntax highlighting.

**The chug was structural, not volume.** `DiffFileBody` put a non-lazy `VStack` of every line inside
a *per-file* horizontal `ScrollView`. The outer `LazyVStack` only deferred whole files, and
virtualisation stopped dead at that nested scroll view — so a file coming near the viewport built
every one of its lines at once, four `Text`s and a `.textSelection` each. The per-file horizontal
scroll chosen earlier the same day was itself the cause. Paging alone would not have fixed it.

Fixes, in the order they mattered:
1. **Flatten to one row per line** (`DiffPage` / `DiffRow` in ClinicCore) and render them directly in
   one `LazyVStack` inside one `ScrollView([.vertical, .horizontal])`. Sections still pin the file
   headers. Virtualisation now reaches individual lines.
2. **Content width by arithmetic**: monospaced font, so `longest line × advance`. Kills the whole
   measuring problem that the earlier `minWidth`/`fixedSize` fight was about, and the width cannot
   jump as lazy rows come and go.
3. **Paging as a line budget** (20,000 rows), extended by a "Show more" row or by clicking a rail
   chip for a file not yet reached (`reveal(path:)` — the rail lists every changed file, so a chip
   that scrolled to nothing was a bug the first screenshot exposed).

Measured before picking the budget: building rows is cheap — 72k rows across 40 files in ~26 ms — so
the array was never the problem and the budget exists for *highlighting* cost, not row cost.

**Syntax highlighting** reuses the tree-sitter stack the editor panel already pulls in
([[ADR-058 Third-Party Packages Allowed]]) and `EditorThemes`' palette, so a file reads the same in
both panes. `CodeLanguage.detectLanguageFrom(url:)` → `.language` + `.queryURL`, query compiled once
per language and cached, parser per call. Each hunk is parsed as **two snippets** — new side
(context + additions), old side (context + deletions) — instead of fetching both whole files;
tree-sitter is error tolerant enough that a fragment still yields keywords, strings, comments and
types. Runs off the main actor *after* the plain text is on screen.

One real bug caught by measuring rather than by looking: the first version did
`captures.filter { intersects(span) }` per line — O(lines × captures), tens of millions of
comparisons on an 1,800-line file. Replaced with a single ordered pass that buckets captures into
their lines.

Verified on a synthetic 40-file, 64,000-line diff: renders, highlights, and sits at **0% CPU idle**
(377 MB RSS) where the old shape was unscrollable. 138/138 tests, 9 of them new for flattening and
paging (budget stops, prefix-not-subset, one enormous file still renders, collapse frees budget).

Two notes for later:
- `CLAUDE.md` still says "No third-party Swift packages (ADR-023)", which ADR-058 superseded on
  2026-09-07. Stale; worth fixing.
- The PR page's Files tab still renders each file's rows non-lazily
  ([[ADR-053 Pull Request Page]]); a large PR will chug the same way the diff panel did. It could
  adopt `DiffScrollView` wholesale.

Follow-up: a one-file diff floated in the middle of the panel. A two-axis `ScrollView` centres
content smaller than its viewport — new behaviour introduced by the virtualisation rewrite, since
the old shape was a vertical-only scroll. The viewport measurement that already existed for the
content width now carries both dimensions, and the stack takes `minHeight: viewport.height` with
`alignment: .topLeading`; tall content is unaffected because its natural height already exceeds the
minimum. Also corrected `CLAUDE.md`, which still forbade third-party packages after
[[ADR-058 Third-Party Packages Allowed]] superseded that on 2026-09-07.

Later still — collapsing files was slow with many files. Measured before touching anything, with a
`-ClinicCollapseAllAfterLaunch` smoke hook that collapses every rendered file in turn and logs the
run (a click cannot be scripted). On the 40-file, 64,000-line repo: the model work was only 164 ms,
but CPU sat pegged at 100–150% for ~18 s afterwards, and the log gave the reason —
`highlighted 12 files … 1559 ms` at load, then `highlighted 24 files … 15332 ms` after collapsing.

Three compounding faults, none of them the one I would have guessed:
1. **Collapsing freed budget, so it pulled in more files** — 12 became 24. Collapsing *added* work.
   The rule is now: the budget decides the page size when the reader asks for more, never on a
   rebuild. Collapsing changes what a page costs, not which files it holds.
2. **Every toggle restarted the whole highlight pass**, re-parsing files already coloured. Now
   incremental: row ids are stable for the life of a diff, so results accumulate per file and only
   new files are parsed.
3. **The highlighter never checked cancellation** — only the caller did, after the whole pass
   returned. Twelve superseded passes each ran to completion, contending on one actor, which is
   where 2× the files became 10× the time. It now checks per file.

Also fixed while in there: `DiffScrollView` took `DiffPage` and the highlight dictionary *by value*.
Both are `Equatable` and enormous, so SwiftUI deep-compared tens of thousands of rows and strings on
every update; the view now takes the model by reference. The rail was worse — it took the entire
`[UnifiedDiffFile]`, every hunk and line of the diff, to draw chips; it takes `DiffFileSummary` now.
And rows are cached per file (`DiffPage.RowCache`), so a rebuild is array assembly, not construction.

Result on the same run: 164 ms → **42 ms**, no re-highlighting at all, CPU flat at ~10% instead of
pegged for 18 s. 140/140 tests, including the new invariant as a test — collapsing must never add or
remove files from the page.

Lesson worth keeping: every one of these was found by measuring, and the timing that mattered was in
the *unified log* (`/usr/bin/log show --predicate 'subsystem == "com.r0adkll.clinic"'`), not in
anything visible on screen. The smoke hook that drives an interaction and logs its duration is the
tool that made it possible; keep reaching for it.

## 2026-09-08 — App icon

Clinic has an app icon: a dark rounded square (`#262320`) holding a bone-white shell chevron next to
an orange plus (`#D97757`) — prompt plus care, the two halves of the name.

The source is one SVG, `scripts/clinic-icon.svg`, already drawn on Apple's macOS icon grid (an 824pt
rounded square, corner radius 185, centred in a 1024pt canvas), so every size is a straight render of
the full canvas onto transparency — no per-size padding maths, no hand-tuned artwork. Because the
mark is that simple, `scripts/make-appicon.sh` regenerates the whole set with `rsvg-convert` (seven
PNGs, 16→1024, shared across the ten `Contents.json` entries). The asset catalog is at
`Sources/Clinic/Assets.xcassets`; `project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME` and
`CFBundleIconName`. Verified in the built bundle: `AppIcon.icns` plus the renditions in `Assets.car`.

Not an ADR — no decision was made here beyond "keep the source vector and regenerate", which the
script encodes. If the icon ever gains per-size artwork (a simplified 16pt mark, say), that is a
decision and needs one.

## 2026-09-08 — Focus modes for the Files panel (ADR-081)

User: *"The 'Files' panel could use some UX love. We should be able to show/hide the file tree.
Additionally, it might be nice to easily expand the selected file to full screen in the app, and/or
open it in a dedicated window."* Three asks, three different answers — the interesting decision was
refusing to build one mechanism for all three.

**The tree toggle is a preference, not pane state.** `EditorPrefs.shared.showTree`, one observable
object read by every Files pane and persisted under `ClinicEditorShowTree`. A flag per `EditorModel`
would have been less code and wrong: hiding the tree says how you read code, not how one pane is
arranged. Its button lives in the *code view's* header — the only chrome on screen in both states, so
the toggle can never hide itself. The pane's minimum width follows it (520 → 360), which meant
`PanelPane.Kind.minWidth` had to become `@MainActor` and the flag had to join `SidePanel.renderKey`:
the width is the one thing the SwiftUI page cannot re-decide for itself, because only the AppKit host
knows about the divider.

**Zoom belongs to the panel, not the editor.** "Full screen in the app" is `SidePanel.isZoomed`, so a
diff, a PR and a shell get it too; zooming a single pane would have needed a second mechanism only the
editor could use. The mechanics matter: `TabContentView` takes the panel *out* of the `NSSplitView`
and pins it over the whole tab, hiding the split view. The obvious implementation — drive the divider
to zero — would resize the agent surface to zero columns and make libghostty reflow scrollback it
would then have to give back at a width it never had. Hidden, the surface keeps its real size and only
its occlusion flag flips. Also had to stop two places from handing the keyboard back to a surface
nobody can see: `focusPanel` and `TerminalStack`'s first-responder fallback.

**A file window is AppKit, not a scene.** `FileWindowController`: plain `NSWindow`, its own
`EditorModel(root:tree:false)`, registry looked up by *the file each window currently shows* so
quick-opening inside a window keeps "one window per path" without a stale key. A `WindowGroup(for:)`
would have dragged in state restoration, which ADR-042 deliberately disarmed. Two buffers on one file
is allowed: ADR-057's watcher reconciliation already handles it (silent reload when clean, prompt when
dirty), and locking one editor out would be the worse answer.

Shared `FileEditorView` (header + `SourceEditor` + quick open + external-change alert) is used by the
panel's right half and by the window; `EditorPanel` keeps the tree and the agent-files list.

Smoke run (second instance, `CLINIC_APP_SUPPORT` isolated): zoom fills the tab, the file window opens
titled and subtitled with its proxy icon, `-ClinicHideFileTree` gives a one-column Files pane, and
hide→show after a zoom puts the panel back in the split view rendering (the blank-panel failure mode
from ADR-079 did not come back). 140/140 tests.

## 2026-09-08 — The Files pane only ever showed its first file (ADR-081 follow-up)

User: *"when clicking a file in the tree it doesn't update the file view."* The cause was in the
vendored editor, not in our view code: `SourceEditor` copies its text binding into the text view in
`makeNSViewController` and **never again** — `updateNSViewController` pushes language, configuration
and editor state, but not text. So the pane kept rendering whichever buffer existed when the
representable was built. Latent since ADR-057: at launch `open` runs before the view exists, so the
first file always looks right and only the second click exposes it. My ADR-081 refactor did not cause
it and did not fix it either.

Fix: the code view is now a `CodeView` whose `.id` is `EditorModel.loadGeneration`, bumped on open,
external reload and revert. A load rebuilds the editor instead of trying to push text into one that
will not take it — and takes the previous file's cursor, scroll position and undo stack with it, which
is the right behaviour regardless (undo could previously replay edits from another file).

Provable now rather than by eye: `-ClinicOpenSecondFileAfterLaunch <path>` opens a file into a Files
pane that is already on screen, which is exactly the tree-click path a smoke test cannot click.

Lesson: when a SwiftUI wrapper around AppKit "ignores" a change, read its `updateNSView*` before
theorising about SwiftUI identity or observation. Half the state a representable accepts at birth is
never accepted again.

## 2026-09-08 — Files pane: empty state stops floating, tree width is remembered (ADR-081)

User: *"The empty state displays mid panel for the files content, when empty the file toolbar should
be at the top. We should also remember the width of the file tree subpanel."*

The floating toolbar was a frame in the wrong place: with no file open the pane's `VStack` shrinks to
its ideal height, and `.frame(maxHeight: .infinity)` on the *pane* centres the whole thing, header and
all. The filling frame belongs on the empty state, not on the pane — then the header sits at the top in
both states and only the placeholder is centred.

Remembering the tree width cost the `HSplitView`. It neither reports the width the user dragged to nor
accepts one back, so the pane is now a plain `HStack` with a 9 pt `TreeResizeHandle` and
`.pointerStyle(.columnResize)` (macOS 15 API; the app targets 15). The handle is a real column rather
than an overlay on a hairline — an overlay wider than its parent is not reliably hit-tested outside the
parent's frame, which is the classic way a hand-rolled splitter ends up ungrabbable.

The bit worth keeping: the stored width is clamped **on the way out** (`EditorPrefs.treeWidth(in:)`),
never on the way in. A panel too narrow for the chosen width borrows from the tree and hands it back
when it widens, instead of quietly rewriting the number the user chose — the same reason
`PanelPane.Kind.minWidth` for a Files pane is now `treeWidth + 330` rather than a constant.

## 2026-09-08 — The hand-rolled splitter was a mistake (ADR-081 correction)

User: *"the width is now remembered. But resizing the file tree / file view is SUPER jittery and
buggy now."* Correct, and the diagnosis is worth keeping because it is two separate feedback loops
stacked on each other:

1. `DragGesture` measures translation in `.local` coordinate space unless told otherwise, and the
   handle **moves as you drag it**. Every frame's translation was measured against an origin that had
   just moved, so the reported delta kept collapsing back toward zero — the pointer and the column
   chase each other. This is the canonical hand-rolled-splitter bug and I walked straight into it.
2. `PanelPane.Kind.minWidth` for a Files pane tracked the live tree width (`treeWidth + 330`), so
   widening the tree moved the *panel's own* `NSSplitView` divider mid-drag, which changed the width
   the tree was being measured in. Layout answering a question that changes the question.

The fix was not `.global` coordinates — it was deleting the handle. `HSplitView` is back, and
persistence is solved by direction instead: the stored width goes **in** as `idealWidth`, read once
into `@State`, and comes **out** through a `GeometryReader` behind the tree (rounded, so layout noise
cannot drift the number). Native divider, native feel, and no view depends on `treeWidth` any more, so
there is no loop left to close. The pane minimum is a constant again.

Lesson: "the framework control does not report what I need" is a reason to change the *direction of
the data*, not to rebuild the control. In from state, out through geometry.

## 2026-09-08 — Tree width, third time lucky; and markdown gets a highlighter (ADR-081)

User: *"Can we make the default tree width smaller? Also, can we add more syntax highlighting for
files? I noticed markdown files are not highlighted."*

**The width.** Default 180 — the tree is a picker, not a reading surface. Making it stick took a third
attempt, and the failure was one I had already declared fixed: `HSplitView` **ignores `idealWidth`**
and hands its first child the maximum its frame allows. So "width in as idealWidth, out through a
GeometryReader" applied nothing and stored 480 (the clamp ceiling) on every launch. I only caught it
because I read `defaults read com.r0adkll.clinic` instead of eyeballing a screenshot — the screenshot
looked plausible both times. Now: a real `.frame(width:)` column, a 9 pt handle whose `DragGesture`
measures in **global** space (the fix I should have made the first time instead of deleting the
handle), live width in `@State`, persisted once on `onEnded`.

**Markdown.** The grammar was never the problem — CodeEditLanguages detects `.md` and parses it fine.
Its captures are `text.title`, `text.literal`, `punctuation.special`; CodeEditSourceEditor's
`CaptureName` has none of them, `fromString` returns nil, and every span renders as plain text. A
`HighlightProviding` implementation can only speak that same vocabulary, so the fix is to scan the
document ourselves and map onto the captures the theme paints. `MarkdownSyntax` lives in ClinicCore
(Foundation-only, 11 tests: fences swallow inline markup, backticks beat emphasis, front matter only
counts at the top, unclosed `*` is just an asterisk); `MarkdownHighlighter` maps kinds to captures.

Also: detection now gets the file's first and last 2 KB, so shebang and modeline files are recognised
(verified: an extensionless `#!/usr/bin/env python3` file highlights as python), plus a small
name/extension table for fish/zsh → bash, Podfile/gemspec → ruby, Package.resolved/jsonc → json.

**Swift 6 note:** `HighlightProviding` comes from a Swift 5 package, so its `@MainActor` completion
closures are non-Sendable — a shape a Swift 6 witness cannot spell, and no amount of `@Sendable` or
`@preconcurrency` *conformance* helps. `@preconcurrency import CodeEditSourceEditor` is the fix.

**Mistake worth recording:** `CLINIC_APP_SUPPORT` isolates a smoke instance's Application Support but
**not** its `UserDefaults` — smoke runs write to the real `com.r0adkll.clinic` domain. Mine set
`ClinicEditorShowTree` and left `ClinicEditorTreeWidth = 480` in the live app. Cleared both; told the
user. Check `defaults read com.r0adkll.clinic` after any smoke run that touches preferences.

## 2026-09-08 — New session screen becomes a composer card (ADR-082)

User: "can we spice up this new session screen? the input box placeholder doesn't align with the actual
typed text. Visually, what are some other design things we can try?" Offered four directions; they took
all four.

**The alignment bug.** The placeholder was overlaid on the *padded* frame with `.padding(14)`, while the
text sat at `padding(8)` plus `NSTextContainer`'s 5pt line-fragment padding — 13pt across, 8pt down. So it
rendered 6pt low. Fix: put the overlay on the `TextEditor` *before* `.padding`, compensating only the 5pt
inset SwiftUI does not expose. Proved it rather than eyeballing it: screenshot the placeholder, relaunch
with the same string typed in, compare first-ink pixel — (72,9) and leftmost x=50 in both.

**The redesign.** Model / effort / worktree moved off their floating toolbar row into a bar *inside* the
prompt box, with a circular send button at its trailing edge and an accent focus ring on the card. The
48pt centred hero shrank to a 40pt icon beside the name, with the repo's current branch as a pill. Effort
is now a five-bar gauge (a dial glyph at Auto) instead of a pop-up, since it is an ordered scale. Three of
the project's recent first prompts sit under the card as clickable pills.

**The wash.** The card sits on a radial gradient of the project's colour. First cut used ADR-050's hashed
monogram hue, which for clinic is purple against a coral icon — clashed. Now `ProjectIconCache.tint(for:)`
averages the icon down to one pixel (un-premultiplied, saturation and brightness floored so a dark icon
still yields a usable hue) and falls back to the hash when there is no icon.

**Two SwiftUI traps, both found by screenshot.** A `Menu` with `.menuStyle(.borderlessButton)` renders only
its label's text and image — the chip capsule and the bar gauge silently vanished. `.menuStyle(.button)` +
`.buttonStyle(.plain)` keeps the custom label. And view-level `.opacity` is dropped in that render path, so
"Auto" showed five fully-lit bars; the fill had to move into the colour itself.

Added `-ClinicDraftPromptOnLaunch` and `-ClinicDraftEffortOnLaunch` (ADR-038 smoke keys) — the screen has
states no smoke run could otherwise reach. Checked `defaults read com.r0adkll.clinic` afterwards: clean.

## 2026-09-08 — Worktree enablement and input (ADR-083)

User on the ADR-082 screen: "the worktree part of this could be better. I don't find its enablement and
input intuitive enough." Fair — I had compressed a boolean *and* a free-text field into a row of pills
whose other two members are menus. Nothing said the pill was a switch, and the branch field was an
unlabelled text run with no indication it was optional or what it produced.

Offered three shapes; user took the toggle-plus-revealed-row. The chip now carries a hollow circle / filled
checkmark, so it reads as a switch beside the two menus. Turning it on reveals a row inside the card:
"New branch from main", a bordered field, and beside it either the live `.claude/worktrees/<name>` or the
explicit "Claude names the worktree if you leave this empty." The header pill becomes `main → fix-resize`
in the accent colour, which puts the consequence where branch context already lives and let the footer go
back to just the ⌘↩ line. Focus follows the toggle, so `@FocusState` is a `Field?` now, not a `Bool`.

Rejected: a single "Runs in" destination menu (merges enablement and input neatly but duplicates the
header pill), and a full-width form row under the card (most conventional, but breaks the one-card look
ADR-082 just bought).

Added `-ClinicDraftWorktreeOnLaunch` / `-ClinicDraftBranchOnLaunch`; screenshotted both states. Live
defaults domain clean afterwards.

## 2026-09-08 — A Marketplace screen for plugins (ADR-084)

User: "add a 'Marketplace' feature for easily installing claude plugins and other skills (like those
from skills.sh, or github). Its own screen, and a navigation item (with icon) in the sidebar above the
projects list and its actions bar."

**Two findings decided the shape before any code.** First, `claude plugin list --json --available`
returns installed plugins *and* the whole catalogue of every added marketplace in ~150 ms, and
`~/.claude/plugins/` already holds `marketplace.json` (author, category, homepage),
`plugin-catalog-cache.json` (install counts, component inventory, per-model token cost) and
`blocklist.json`. So the screen needs no network code and no API key at all. Second, **skills.sh is
not usable**: its documented `/api/v1/skills*` endpoints answer `401 authentication_required` and want
a Vercel OIDC token, which a Mac app cannot get. `npx skills find <q>` does work headlessly but prints
ANSI-coloured prose, not JSON. Offered the user both with their costs; they took Claude plugins only.
GitHub needs no separate path — `claude plugin marketplace add owner/repo` *is* the GitHub path.

**ADR-018 was the real design question.** Installing writes `~/.claude`, which ADR-018 forbids without
its own ADR. ADR-084 amends rather than repeals it: Clinic still writes nothing there — mutations are
argv handed to the `claude` CLI, each user-initiated and shown in full in a confirmation sheet before
it runs (`claude plugin install foo@bar --scope user -y`), with the CLI's own stderr shown verbatim on
failure. Editing those files directly stays forbidden.

**CLI facts worth keeping**, all probed rather than assumed: `install`/`uninstall`/`update` *require*
`-y` when stdout is not a TTY; `enable`/`disable` auto-detect scope and **reject** `-y`; the
`marketplace` subcommands reject `-y` too and prompt for nothing (`claude plugin marketplace add --help`
prints the *parent* help, so the flags had to be probed with a bogus repo). Failures exit 1 and write
to **stderr**, decorated with `✘` and ANSI — `PluginError.plain` strips both.

**A latent bug found on the way.** `ProcessEnvironment.toolPaths` prepended only `/opt/homebrew/bin`
and `/usr/local/bin`. This machine's `claude` is at `~/.local/bin/claude` — where Claude Code's own
installer puts it — so a GUI-launched Clinic could not find it, which also affected background agents
(ADR-061). `~/.local/bin` joined the list. The gh/claude process plumbing (the concurrent two-pipe
drain that stops a chatty stderr deadlocking stdout) moved into a shared `ToolProcess` rather than
being copy-pasted.

**Testing.** Fixture tests cover every parser, the merge and all nine argv shapes (35 → 161 tests
green). Then the whole thing was driven for real: a smoke instance launched with **both**
`CLINIC_APP_SUPPORT` *and* `CLAUDE_CONFIG_DIR` pointed at throwaway dirs — the second is the trick
worth remembering, since it isolates the *plugin* state too, so a live install/uninstall round trip
never touches the real `~/.claude`. Added a marketplace from empty (292 plugins appeared), installed
`agent-sdk-dev`, disabled it, uninstalled it, and watched the UI follow each step; `claude plugin list
--json` agreed at every one. Real config verified untouched afterwards, and `defaults read` clean.

Not verified by hand: the "Claude Code was not found" empty state (would need `claude` off PATH
entirely), and Update on a plugin that actually has a newer version.

Small trap: the first synthetic click missed Install by 5 pt because the detail card is *shorter*
before a plugin is installed — no version chip, no Installed badge. Screenshot, measure, re-click.

**Follow-up the same session:** user found the nav row too padded. It had inherited the project
header's 22 pt glyph *box*, but a 13 pt symbol only fills 13 of it — so the accent capsule was 28 pt
tall around a 17 pt label. Kept the 22 pt column (alignment) and dropped the glyph's height to 16
with 2 pt vertical padding: 28 → 21 pt, still label-aligned with the project names beneath it.

**Icon.** User asked for options, so all ten candidates were rendered to a PNG at the real 13 pt size
in both states (accent-filled and idle) with `NSImage(systemSymbolName:)` and shown through the
`show_image` MCP tool — cheaper and fairer than ten builds. User picked `storefront.fill`. Reasoning
worth keeping: the shopping glyphs (`bag`, `cart`, `basket`, `tag`) all imply purchase and nothing here
is bought, and `puzzlepiece` was wrong for a different reason — the plugin *rows* already wear it, so
the destination was wearing its own contents' icon. The screen header now matches the row that opens it.

**Padding, second pass.** User: "much less horizontal padding." The real cost was not the pill's inset
but its *interior*: the row had borrowed a project header's 12 pt disclosure column plus a 22 pt glyph
column, so the label started 62 pt from the window edge. Dropping both (18×16 glyph box, 6 pt interior)
brought the label to 36 pt and the glyph to 24. Cutting the outer inset 10 → 6 as well was a step too
far — measured by pixel column, it put the pill 4 pt left of the search field directly above it — so
the outer 10 came back: the box aligns with everything else in the sidebar, only its contents shrank.
The alignment-to-project-names argument in ADR-084 was simply wrong: this row sits *above* the toolbar
and divider, outside the outline it was aligning to.

**Padding, third pass.** 2 pt vertical read too tight once the horizontal indent was gone — the pill
looked squashed under the 30 pt search field. 4 pt gives a 24 pt row: settled between the original 28
and the over-corrected 20.

## 2026-09-08 — Tab titles follow the session name live (ADR-031 fix)

User: after Clinic or the model names a session, only the sidebar picks the name up; the tab keeps its
old one until the session is closed and reopened.

`Tab.title` was a stored copy, refreshed from `SessionStore` only inside `handle(hookEvent:)` for
`SessionStart` / `Stop` / `PostModelSwitch`. The sidebar has no such copy — it calls
`sessions.displayName(for:)` in its body, so every watcher rescan reaches it. The CLI writes its
`ai-title` record *after* the turn's `Stop` hook, so the record arrived through the watcher with no hook
behind it and the tab bar never heard about it. A manual Rename… (which only touches
`state.manualNames`) had the same hole; `set_session_title` was the one path that worked, because it
poked `tab.title` by hand as well.

Fix: delete the copy. The stored property is now `openedTitle` — the name a tab opened with — and
`title` is computed: session and replay tabs read `SessionStore` on every access, shells and
not-yet-on-disk sessions (a new session, a fork awaiting its id) fall back to `openedTitle`. Because
`SessionStore` is `@Observable`, reading it inside the computed getter registers the dependency in
whatever view body asked, so the tab chip, the window title and the status-item menu all update at the
same moment as the sidebar. `refreshTitle` and the hand write in `set_session_title` are gone; the
`Task` on those hooks still refreshes the store, only its title side-effect went away.

ADR-031 already says "names update live as the tail scan sees new title records", so this is the ADR
being honoured rather than changed. Build only — verifying the timing for real would mean a live
session waiting on the CLI's own title generation.

## 2026-09-08 — Collapsed usage panel is a snapshot (ADR-085)

User: the collapsed usage panel should carry a small snapshot of current usage. Offered three layouts
(inline meters / headline + edge bar / compact list); user picked inline meters, reset times on
hover only.

Collapsed is now one row of chips — `5h ▰▰▱▱ 47%  7d ▰▱▱▱ 45%  Fable ▰▰▰▱ 70%` — at the panel's
existing height, and the whole row is the disclosure control. Expanded is untouched. Two things
worth keeping: the percent stays secondary ink unless the limit is actually pressing (three
accent-red numbers in a row read as three alarms, which is worse than no snapshot), and
`ViewThatFits` over `UsageSnapshot.compactBars(limit:)` drops the *calmest* chip first rather than
the last one, so an exceeded scoped limit outlives a quiet session one. `compactBars` and
`shortTitle` are pure ClinicCore, so the drop order is a test.

Verified against the live endpoint at 322 pt (three chips) and 222 pt (two), plus the expanded panel.

Two build/harness traps cost most of the session:
- `xcodebuild -project Clinic.xcodeproj -scheme Clinic build` writes to **shared DerivedData**, not
  `./build`. The app everything runs from is `./build/...`, which `make build` produces via
  `-derivedDataPath build`. Three screenshots were of a stale binary before this surfaced. Always
  `make build`.
- Seeding a narrow sidebar through the argument domain (`-"NSSplitView Subview Frames main-AppWindow-1,
  SidebarNavigationSplitView" '(...)'`) is read-only going in, but the smoke instance **wrote 228 back
  into the real `com.r0adkll.clinic` domain on quit**. Restored to 322; `ClinicUsageExpanded` was
  likewise flipped to 0 and restored to 1. The ADR-077-era warning about smoke instances and shared
  UserDefaults applies to window/split geometry too, not just panel widths.

## 2026-09-08 — The PR tab could not find `gh`, and the panel got rebuilt (ADR-086, ADR-087)

User: "The PR tab doesn't seem to be working. It says to login to the gh cli, but that is logged in.
I also think we could completely re-think the design of this screen too."

**The bug was PATH, not auth.** `gh` is at `~/.nix-profile/bin/gh` here. A GUI-launched app gets
launchd's `/usr/bin:/bin:/usr/sbin:/sbin`, and `ProcessEnvironment.toolPaths` only prepended the two
Homebrew prefixes and `~/.local/bin` — so `/usr/bin/env gh` exited 127, `isAvailable()` returned
false, and the panel's single failure message told a logged-in user to log in. Proved it with a
throwaway test under `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin`: 127 before, `.ready` after.

ADR-084 had already hit this once and answered by appending `~/.local/bin` to the constant. Nix was
the second miss, so ADR-086 stops growing the list and asks the login shell instead
(`$SHELL -l -c '/usr/bin/printenv PATH'`, once per launch, prewarmed off the main thread, 3 s
timeout, empty on failure). `printenv`, not `echo $PATH` — fish would print a space-separated list.
Login rather than interactive, because interactive can block on a prompt; the hardcoded prefixes stay
as the fallback that covers what a login shell misses (zsh `-l -c` skips `.zshrc`, which is where
`~/.local/bin` comes from — so ADR-084's entry still earns its keep).

Second half of the same bug: `isAvailable() -> Bool` collapsed "missing" and "logged out". Now
`Availability` is `.ready` / `.notInstalled(searchedPath:)` / `.notAuthenticated(stderr)`, exit 127
being the discriminator, and the panel renders each with a Retry button.

**Panel redesign (ADR-087).** Offered three directions; user picked status-first single scroll. The
judgement moved into `PullRequestStatus` in ClinicCore — tone-ordered lines, one suggested action,
`canMerge` — so the wording is a unit test, not a screenshot. The raw `mergeable`/`mergeStateStatus`/
`reviewDecision` grid is gone. Two things real data changed after the first draft: the draft line had
to be *pinned above* the tone sort (it reframes every line under it, so it cannot rank last as
neutral), and an approving review had to stop counting as an "unanswered comment" — that rule now
lives once and `PullRequestMark` calls it, which fixes the sidebar summary too.

Traps worth remembering:
- **`make build` pipes xcodebuild through `tail -20`, which swallows `error:` lines.** A failed build
  printed only "(5 failures)" and the failing task names. Run the bare `xcodebuild -project
  Clinic.xcodeproj -scheme Clinic -configuration Debug -derivedDataPath build …` and grep `error:`
  when `make build` fails; the flags are identical, so it is the same build.
- **`open -n --env …` propagates the calling shell's `PATH` to the app**, so a smoke instance does
  *not* reproduce the launchd environment by default. A first attempt at the missing-`gh` screen
  silently exercised the working path. Pass `--env PATH=/usr/bin:/bin:/usr/sbin:/sbin` explicitly
  (and `--env SHELL=/nonexistent-shell` to defeat the new login-shell layer) to get the real thing.
- Seeding a smoke instance with a PR: `CLAUDE_CONFIG_DIR=<tmp>` plus a hand-written
  `projects/<encoded-cwd>/<uuid>.jsonl` holding a `{"type":"pr-link",…}` record, and a
  `CLINIC_APP_SUPPORT=<tmp>/Clinic/state.json` whose `ownedSessions` names that uuid. Cheaper than it
  looks and gives a real PR against live `gh`. Checked `ClinicPanelWidth`/`ClinicRightPaneWidth`
  before and after — unchanged, nothing leaked into the real defaults domain this time.

## 2026-09-09 — Pull request glyph (ADR-088)

User asked for a better PR icon, pointing at "the iOS glyphs" or an icon set already in the project.

Probed what this macOS actually ships rather than guessing from memory: SF Symbols 6's
`arrow.trianglehead.{pull,merge,branch}` all resolve on macOS 15, and CodeEditSymbols (already
vendored via CodeEditSourceEditor) carries `branch`, `commit`, `checkout`, `github` — its `branch` is
the octicon two-dots-and-a-curve.

Rendered the candidates at the sizes Clinic actually draws them, in a real PRChip, on the panel's
background. That killed the obvious answer: `arrow.trianglehead.pull` is the *correct* symbol and its
redraw is real, but it only shows above ~20 pt, and every place Clinic draws a PR glyph is 13 pt.
Offered the comparison; user picked `point.topleft.down.to.point.bottomright.curvepath` — GitHub's
own shape, the only candidate that is not just "an arrow" in a chip.

Bound it once as `PullRequestMark.symbol` in ClinicCore instead of repeating a 49-character symbol
name at four call sites; the test asserts against the constant now. `merge`/`branch` still moved to
the trianglehead family — they are drawn larger and in prose, where the solid head reads.

Method note worth keeping: for any icon question, render the candidates *at the real size, in the
real container, on the real background* before deciding. The 26 pt blow-up said "trianglehead is
clearly better"; the 13 pt chip said "you cannot tell these apart". Only the second one matters.

Also: `ClinicPanelWidth` read 626 on 2026-09-08 and 761 today. Initially suspected a smoke instance,
but a second smoke run left it at 761 untouched — it was the live app being resized by the user.
Check twice before "restoring" a preference; the earlier ADR-077-era warning makes it tempting to
assume the smoke instance did it.

## 2026-09-09 — The PR glyph was the right one all along, at the wrong size (ADR-089)

User: "Lets try the arrow.trianglehead.pull, but lets make the icons larger so they appear visually
correct." That supersedes this morning's ADR-088.

The ADR-088 comparison was not wrong about what it measured — at 12 pt in a chip, the arrow really is
indistinguishable from any other small arrow. It was wrong about what was variable. Every PR glyph
inherited the point size of the text beside it (`.callout` 12, `.caption` 10, `.body` 13); nobody had
ever *chosen* a size. `arrow.trianglehead.pull` is a tall narrow shape — stroke, stub, solid head —
so at the same nominal size as `terminal` or `doc.text.magnifyingglass` it lays down much less ink
and reads smaller. That is a glyph owed optical compensation, not a glyph to reject.

Sizes now live in one table, `PRStyle.glyphSize` (chip 14, sidebar 12, header 15, status line 13,
tab strip 12), each ~2 pt over its neighbouring text. The panel tab strip compensates per kind via
`PanelPane.Kind.glyphSize` — 10 pt for the boxy glyphs, 12 for `.pr` — so the strip is optically even
rather than nominally even. Status-line glyph frame went 14 → 16 pt so the text column does not
shift. Verified at all four sites in a smoke instance.

The lesson generalises past icons: **when something looks wrong, check whether the property was ever
chosen before concluding the thing itself is wrong.** Inheriting a text style is a default, not a
decision — and yesterday's method note ("render at the real size") is only half the tool if the real
size is itself an accident.

Because `PullRequestMark.symbol` was already bound once (ADR-088's one durable idea), swapping the
symbol back was a single line.

## 2026-09-09 — GitHub renders the bodies now (ADR-090)

User: "For the comments and description we should render all of github's markdown / html (like images
and the like)."

Checked how bad it actually was before choosing an approach: across the user's real Campfire PRs,
comments carry 18 raw `<table>` blocks and 21 Markdown tables. Danger posts its whole report as raw
HTML, so Clinic was showing the reader the tags *and* the `<!-- DangerID -->` comment. That single
fact decided the design — no Markdown-only renderer can ever fix it, which ruled out
swift-markdown-ui before it was worth evaluating further.

The find that made this cheap: **`gh` returns GitHub's own rendered HTML.** `bodyHTML` over GraphQL
(or `body_html` with `Accept: application/vnd.github.full+json`) on PRs, issue comments, reviews and
review comments. No parser to write, and fidelity is exact by construction — images, raw tables,
`<details>`, alerts, task lists, emoji shortcodes, `@mentions`, issue cross-references.

Took GraphQL over REST for one reason worth remembering: **its node ids are the same ids
`gh pr view --json comments,reviews` already returns**, so merging rendered HTML into the parsed PR
is a dictionary lookup. REST's numeric ids would have forced matching on author + timestamp.

Two operational details that are easy to miss:
- **The embedded image URLs are signed and expire in ~300 s** (`X-Amz-Expires=300`). So the HTML is
  re-fetched on every refresh rather than cached; ADR-053's existing 5-minute poll happens to be
  exactly the right cadence.
- The fetch is a **separate, non-fatal call**. `bodyHTML` is optional and the panel falls back to the
  Markdown source, so a GraphQL failure cannot blank a PR that already loaded. `MarkdownText` stays
  alive as that fallback rather than being deleted.

The web view is locked down: CSP `default-src 'none'` with images allowed, scripts confined to a
per-load nonce (so only the height reporter runs), links opened in the browser and every other
navigation refused. Comment bodies are written by strangers; that is the boundary that makes
embedding them safe. Height comes from a `ResizeObserver`, not a one-shot measure, because the case
that matters is an image finishing its download.

Known cost, written into the ADR rather than discovered later: **one WKWebView per body.** Fine today
(Conversation is collapsed and lazy); if a 50-comment PR ever hurts, the fix is one document for the
whole section instead of one per comment.

Verified against the user's test PR (raw `<img>` GIF in body and comment) and Campfire #1057 (Danger
tables, cross-references, merged header).

Commit-signing trap: commits here are SSH-signed through the 1Password agent (`gpg.format=ssh`,
`commit.gpgsign=true`), and while it was locked every `git commit` failed with
`error: 1Password: failed to fill whole buffer`. When it unlocked, the ADR-089 changes were *still
staged* from the failed attempt, so `git add -A` swept them into the ADR-090 commit under a message
naming only ADR-090. Split afterwards with a backup branch (`git branch _split_backup <sha>`,
`git reset --hard <parent>`, `git checkout <backup> -- .`, peel the later change back out, commit,
then `git checkout <backup> -- .` again) — verified by `git diff <backup> HEAD` coming back empty.
Lesson: **after a signing failure, re-check what is staged before the next `git add -A`** — a failed
commit leaves the index loaded, and the next commit silently absorbs it.

## 2026-09-09 — PR panel: tabs, a files tree, and the scroll bug ADR-090 caused (ADR-091)

User reported four things: the design "is lacking", Checks and Files should be tabs, Files should use
a tree + single-file viewer "like we do on other screens" with syntax highlighting, and "the webviews
eat scrolling gestures".

The last one was a regression I shipped yesterday. `WKWebView` consumes the wheel event, so with the
pointer over any body — most of the panel — the whole panel refused to scroll. Fix is a `WKWebView`
subclass forwarding vertical scrolls to `nextResponder`; horizontal is kept so a wide `<table>` still
scrolls sideways. The direction is latched at `phase.began` and held through momentum — deciding per
event let a flick a few degrees off-axis switch owners mid-gesture and stall.

Layout is now header / pinned status / tabs (Conversation, Checks, Files). Status stays pinned rather
than becoming a tab: ADR-087 exists precisely because "is this mergeable" needed a click.

Two things I only learned by *using* the thing, not by reasoning about it:
- **The first Files render had a huge empty gap and wrapped every line.** Both were rules ADR-080 had
  already discovered and that I did not inherit by building a second scroll: content width from the
  monospaced advance (else rows wrap), and `minHeight: viewport.height` (else a two-axis ScrollView
  centres short content in the middle of the pane). If you build a new diff scroll, copy both.
- **A PR file tree needs single-child chain compression.** It holds only touched paths, so Kotlin gives
  `infra/audioplayer/api/src/commonMain/kotlin/com/…` — every level with one child, six clicks to a
  file. GitHub and VS Code both fold these. Only visible once a real multi-module PR was on screen;
  the clinic repo's own shallow paths would never have shown it.

Reuse that paid off: `FileTreeNode.build` + `FileGlyph` (ADR-081), `DiffPage.build` → `DiffRowView` +
`DiffSyntaxHighlighter` (ADR-080). `DiffFileRows` has no public init, so the one-file page goes through
`DiffPage.build(files:limit:)` — which happens to be exactly the type the highlighter takes.

Avatars came free: the ADR-090 GraphQL call just needed `author{login avatarUrl}` added, keyed by login
since a person's avatar is the same in every comment. The conversation is now a rail with avatars on
it rather than detached cards, which is what actually made it read as a thread.

## 2026-09-09 — Filter and hide the PR file list (ADR-092)

User: filter/search the files in the PR Files tab, and be able to collapse the tree.

Reused `FuzzyMatcher` (ADR-081's Quick Open matcher) rather than writing substring filtering, so
"search" means one thing across the app. Filtering swaps the tree for a flat ranked list — searching
and browsing are different acts, and the hierarchy is noise once you are typing a name. A "13 of 19"
count sits opposite the field because fuzzy matching is loose enough that the reader should see how
much it actually narrowed.

The toggle lives in a toolbar row present in *both* states, so it can never hide itself (the editor
panel's rule). With the list hidden the row shows the open file's path instead. The filter field
belongs to the list and disappears with it: a search box returning results into a hidden pane would
be a puzzle. Own key, `ClinicPRShowTree`, not the editor's — different surfaces.

**Two harness mistakes worth not repeating:**
- **`winlist | head -1` picked the user's live Clinic**, and I drove three clicks into it before
  noticing the content was the clinic repo tree rather than the Campfire PR. Nothing destructive, but
  it moved their app. Always pick the window by checking the owning pid's environment for
  `clinic-smoke` — never by position in the list. Added a loop that does this.
- **A newly-launched smoke window is not focused**, so the first click only activates it and is
  swallowed. Click the target twice, or click once to focus and then proceed.

Also: the smoke run wrote `ClinicPRShowTree=0` and `ClinicPRTreeWidth=187` into the *real*
`com.r0adkll.clinic` domain (the CLINIC_APP_SUPPORT/UserDefaults split, as always). Both were new keys
the user had never set, so I deleted them rather than restoring a value — leaving them would have
shipped the feature to them with the tree already hidden. **Check for keys a new feature introduces,
not just ones that existed before the run.**

## 2026-09-09 — Design an MCP configuration screen (ADR-093, supersedes ADR-060)

User wanted to configure "local and global" MCP servers from inside Clinic. Explored against the real
`claude mcp` CLI in a scratch `CLAUDE_CONFIG_DIR` before proposing anything; the CLI's shape decided
most of the design.

The findings that mattered: **`add` refuses to overwrite** (exit 1), so there is no edit — only
remove-then-add, with a gap and a rollback. **`mcp list` has no `--json`**, health-checks for ~3.8 s
and only sees `cwd`'s project, so it cannot back the list; reads stay on disk and the CLI is for
writes plus on-demand status. **There is no `disable`** — `.mcp.json` approval lives in
`enabled/disabledMcpjsonServers`, written only by a session prompt, so Clinic cannot offer a toggle
without breaking ADR-018. Said so on the screen rather than inventing one. **`add-json` exists**, and
since every MCP README ships a JSON snippet, paste-JSON became the headline affordance rather than a
convenience — build it before the form.

Named the vocabulary trap explicitly: two of Claude's three scopes are "local". Kept the CLI's names
so the mapping survives, subtitled each, and refused to inherit the CLI's `local` default silently.

Two deviations recorded rather than smuggled: the command preview is **redacted**, not "shown in
full" as ADR-084 promised, because an API key in full is worse; and the redaction is display-only —
the value still goes through argv and lands in `~/.claude.json` in plaintext, which the screen admits.

**Bug found on the way:** `MCPServersConfig.configFileURL` computes `configDirectory/../.claude.json`.
Correct for the default (`~/.claude` → `~/.claude.json`), wrong under `CLAUDE_CONFIG_DIR`, where the
CLI writes *inside* the directory — watched it do so. Every smoke instance has been reading the real
`~/.claude.json`, which made the sheet look right for the wrong reason. ADR-060's "sibling file" was
just mistaken; ADR-093 corrects it.

Also proposed shrinking `WindowState`'s pairwise exclusivity to `screen: Screen?` before a fourth
content mode makes it twelve `didSet` assignments — but left `editingDraft` alone, since it is
mutated through the optional (`tabs.editingDraft?.prompt = …`) and an enum payload would fight that.

Glyph is `powerplug.fill` (`network`/`terminal` are the row badges, out by ADR-084's rule;
`server.rack` mushes at 13 pt). Availability confirmed, **the at-size render comparison is still
owed** — did not pretend to have run ADR-084's ten-candidate check.

Nothing implemented. No writes to the real `~/.claude.json`; every scratch mutation reported the
scratch path.

## 2026-09-09 (later) — Build the MCP configuration screen (ADR-093)

Implemented in the order the ADR set: reader fix and paste-JSON first. `ClinicCore/MCP/MCPService`
(actor over `claude mcp`, static `arguments(for:)`), `MCPServersConfig` rewritten around the CLI's own
scope names, `MCPServersScreen` + `MCPServersModel` + `MCPServerFormSheet`, ADR-060's sheet deleted.
206 core tests green (23 new). Verified on screen in a smoke instance with a scratch
`CLAUDE_CONFIG_DIR`; the real `~/.claude.json` was byte-identical (shasum) before and after, and the
run introduced no new keys in the real defaults domain.

**Verified end to end on screen:** nav row, list grouped by scope with "Show all projects", detail
pane with masked env/header values, live `claude mcp get` health (a real HTTP 401 from Sentry rendered
as `.failed` with its issue truncated), paste-JSON → parsed row → Use → filled form, redacted command
preview, confirm sheet, and a real `add-json` writing to the scratch config. Then a full two-step
edit: the confirm sheet listed `remove` then `add-json` in order and both ran, `sentry` surviving.

**Every mutation goes through the CLI as one `add-json`**, not `-e`/`-H`/`--` argv assembly. Same code
path for the form and for a pasted snippet, and no separator subtleties to get wrong.

**Entries carry key *names* only.** `MCPServersConfig.load` never reads env or header values; the edit
path re-reads the definition from disk at the moment it needs it, so secrets never sit in an
observable model. Also: `claude mcp get` prints env values and headers in plaintext, so the health
parser keeps only the `Status:`/`Issue:` lines and truncates the issue to 200 chars — a failing HTTP
server returned an entire HTML page as its issue during testing.

**Rollback premise verified against the real CLI**, not just assumed: `remove` succeeds, a bad
`add-json` exits 1 leaving the server gone, re-adding the snapshot restores it byte-for-byte. There
is no app-level test target (ClinicCore is the only one), so the two decisions that are easy to get
wrong moved into `MCPEditRecovery` in ClinicCore and are unit-tested there — notably that a failure on
the *first* step must NOT restore, or it would add back a server that was never removed.

**Four refinements found by using it, none contradicting the ADR:**
- Command preview escaped `https:\/\/` (JSONSerialization's default). `.withoutEscapingSlashes` — the
  string is shown to a human, not just parsed.
- After a run, `health = [:]` left the detail's status box rendering *empty*, because `.task(id:)`
  does not re-fire for a selection that never changed. Added a "Not checked" branch and a forced
  re-check of the selected server.
- The project picker defaulted to "Chats", a pseudo-project with no repo and no `.mcp.json`. Now the
  first real project.
- The Name placeholder was `hardcover` — indistinguishable from a filled-in value when a server of
  that name exists. Now `my-server`.

Dropped the ADR's "keep `showingMarketplace` as a computed shim": the setter's semantics were
confusing and there were only six call sites, so `WindowState.screen` replaced them outright.

**Pre-existing break found and left alone:** `ProjectViews.swift:96` calls `OpenInMenu`, which
ADR-078 renamed. I "fixed" it before realising **my own edit had deleted the definition** — I replaced
`SidebarView.swift` from a marker to EOF and dropped 370 lines including `struct OpenInMenu`, then
grepped, found nothing, and concluded `main` was broken. Restored from HEAD and reapplied the two
intended edits. **Never anchor a whole-file rewrite on "from marker to end of file"; bound the
replacement by the next top-level declaration** (what the second attempt did).

Smoke-driving notes: synthetic clicks on an open `Menu` dismiss it without selecting — drive menus by
keyboard instead, but an `NSPopUpButton`'s arrow keys jump to first/last rather than stepping, so
click the item directly inside the *same* run. `TextEditor` ignores `keyboardSetUnicodeString`; set
the pasteboard and send ⌘V. `screencapture -l` picks the sheet once one is open — select the window
by largest area, or capture `-D 1`.

Not verified by hand: Log In / Log Out (needs a real OAuth server), Import from Claude Desktop, Reset
Approval Choices, `.mcp.json` approval pills (no project-scoped server to hand), and the rollback
branch *through the UI* (its premise and its decision logic are both tested). The `powerplug.fill`
glyph still owes ADR-084's at-size render comparison.

## 2026-09-09 (later still) — The MCP glyph, decided on evidence (ADR-093 amended)

User: *"i wonder if a 'server' icon for MCP sidebar item would be better?"* — which is exactly the
check ADR-093 had deferred, so I ran it rather than argued from memory: ten candidates rendered at the
row's real metrics (13 pt in an 18×16 box, semibold callout), unselected and accent-filled.

**My ADR reasoning had been wrong on the facts.** `server.rack` does not "mush at 13 pt" — it is the
most legible mark of the set. `powerplug.fill` is the one that collapses: at this size the prongs
merge into the body and it stops reading as a plug at all.

**The real objection only appeared in the stacked view**, which the first contact sheet did not have:
`server.rack` under `storefront.fill` twins it — same rounded box, same mass, divided interior. So I
re-rendered the candidates *in their actual adjacency*, which is the lesson worth keeping: **render
the neighbours, not just the glyph.** A single-column contact sheet cannot show an adjacency fault.

Went with `server.rack` anyway: unambiguous semantics beat a similarity that two different labels
resolve on first read. Verified in the running app, selected and unselected — in situ the awning and
the rack bands separate more cleanly than the mock suggested. Recorded the similarity in the ADR as a
live constraint: a third box-shaped destination in the pinned nav block is the trigger to revisit.

Amended ADR-093 in place rather than writing a superseding ADR, because ADR-093 had explicitly
reserved this decision ("the visual check is owed before it ships") — completing a deferred choice,
not deviating from a settled one.

Two renderer traps: `NSImage` template + `fill(using: .sourceAtop)` wipes the alpha and draws every
symbol as a solid block — use `SymbolConfiguration(paletteColors:)`. And a smoke window's origin is
not stable across relaunches, so window-local click coords go stale; prefer absolute screen points.

## 2026-09-09 (later) — Marketplace filters by what a plugin adds (ADR-094)

User: *"could we add tabs/filters for the type of 'plugins' to install. Such as Skills, Agents, Commands,
MCP, etc"* — and the first thing worth checking was whether Claude Code has such a type at all. **It does
not.** A plugin is a bundle: `superpowers` is 14 skills *and* a hook, `vercel` is 33 skills, an MCP server
and two hooks. So tabs were the wrong shape — they partition, and a plugin belongs to several kinds at
once. Chips that filter, not tabs that file.

Measured the axis before designing it rather than assuming coverage: 291 plugins in
`plugin-catalog-cache.json`, of which 237 add skills, 124 an MCP server, 57 hooks, 51 commands, 33 agents,
14 LSP servers. Every one carries a full `components` block, so the facet is real and dense — worth a
persistent bar, not a menu.

Order of the chips is the *user's* phrasing (Skills, Agents, Commands, MCP, Hooks, LSP), not the
catalogue's prevalence order, so the bar does not reshuffle when a marketplace is added.

Two details that only showed up on screen:
- **`bolt.horizontal` for Hooks is an anonymous squiggle at 13 pt.** Swapped for `bolt`, which reads
  instantly — the ADR-093 lesson again: render it in the bar with its neighbours, not on its own.
- **A selected chip whose count falls to zero must stay in the bar.** Dropping empty kinds is right, but
  dropping the one that is *doing* the filtering leaves no way to turn it off.

Smoke-driving: `CGEvent.postToPid` mouse clicks **do not activate SwiftUI buttons** — the hover highlight
appears, the action never fires (cost four rounds of screenshots today). `post(tap: .cghidEventTap)` works.
Guarded it: the helper refuses to click unless the target pid is frontmost *and* the point is inside a
window that pid owns, which is the missing check behind the 2026-09-09 misfire into the live app.
Also: the opaque-alpha bounding box of a `screencapture -l` PNG gives the exact content rect
(`x=112 y=76` of shadow padding here), so `screen_pt = (px − 112)/2 + winX, (py − 76)/2 + winY` — measuring
the shadow beats guessing it symmetric.

`ClinicCore` gained `PluginKind`, and `PluginComponents.groups` is keyed by it, so the detail pane's
"What it adds" and the filter bar cannot drift apart on names. Filter is per-run state like `query` and
`category`; nothing new is persisted (checked `defaults read com.r0adkll.clinic` after the run).

## 2026-09-09 (later still) — Automations designed on probe evidence (ADR-095)

User asked for an Automations screen: cron-schedule a prompt in a project or a chat, name it, pick from
template tiles, manage the configured ones. The screen was never the hard part — ADR-084 and ADR-093
settled that shape twice. **The hard question was what actually runs at 9 a.m.**, so I probed the CLI
with four throwaway `--bg` sessions before designing anything (all stopped, `claude rm`'d, worktree and
branch list verified clean afterwards).

**The finding the whole design rests on: Clinic's hooks fire for a `--bg` run.** A `--settings` file
pointing at a scratch script produced `SessionStart` (`source: startup`) and `Stop` with the real
`session_id`. So a scheduled run joins the state machine, the sidebar, attention, notifications, the
transcript reader and the snapshot store *for free*. An automation run **is** a background agent; the
feature is a scheduler, a saved prompt and a launcher, and the whole downstream already exists. The two
alternatives — a visible tab, or headless `claude -p` — either fire at a window nobody is watching or
throw away everything Clinic has built.

Five constraints the probes imposed, none of them documented anywhere:
- **`--bg` refuses `--session-id`** ("--bg manages the session id"). ADR-017's pre-assignment does not
  hold. But the printed short id is the full UUID's first 8 chars, so correlation is deterministic —
  parse stdout, bind the next matching `SessionStart`. Same rebind machinery ADR-063 built for forks.
- **A finished bg agent stays resident**: `status: idle, state: done`, pid alive, attachable. A daily
  automation leaks one `claude` process per run forever. Reaping is a requirement, not a nicety.
- **`--bg` accepts `-w`**, creating a *locked* worktree with the agent's cwd inside it.
- **`claude rm <id>` reaps the worktree, branch and lock too** — `claude stop` says so in its own
  output. So "fresh worktree per run" costs one CLI call, not a git dance. ADR-061 described `rm` as
  job state only; corrected.
- **`claude logs <id>` is a raw ANSI TUI replay** — 4 KB of cursor addressing for a five-word answer.
  Run output must come from the transcript `SessionStart` hands us. Reinforced the hook-based design.

**A defect fell out on the way**: `BackgroundAgent.isRunning` treats completed/failed/stopped as
terminal, but the CLI reports **`done`** with `status: idle` — so every finished agent currently reads
as running, and every automation would have looked permanently in-flight. Same shape as the
undocumented `blocked` that `needsAttention` already had to learn.

**The launchd question resolved itself once framed properly.** The user chose "in-app now, launchd
behind a preference", and I had framed that as two scheduling paths to keep honest. It isn't: launchd
is a *wake-up*, not a scheduler. A static bundled `SMAppService.agent` with `StartInterval 300` runs a
new `clinic-wake` helper that does `open -g -j -b com.r0adkll.clinic`, and the one in-app scheduler
does all the work in its normal catch-up pass. Static plist over a dynamic one in `~/Library/LaunchAgents`
because computed `StartCalendarInterval` means regenerating and re-bootstrapping on every edit and
`* * * * *` expands to sixty dicts; the price is 5-minute granularity, stated on screen. And explicit
Quit writes a suppression marker the helper checks — an app that resurrects itself four minutes after
you quit it is hostile, and that is one line of code to prevent.

**Worktree isolation follows the permission posture**, which is the tidiest thing in the design: a
`plan`-mode report automation cannot write, so it gets no worktree; an `acceptEdits` one gets a fresh
worktree per run. A run that ends with no commits and a clean tree is `claude rm`'d immediately — *a run
that changed nothing leaves nothing behind* — which is what stops "fresh worktree per run" becoming
thirty directories a month. Anything with work in it is retained and only ever offered for removal.

Also settled: templates ship as bundled JSON (adding one is data, and ADR-086's tool discovery greys out
the ones whose `gh` is missing), eight in v1 split evenly between read-only reports that structurally
cannot stall and code-touching jobs worth their worktree; run history in a sibling
`automation-runs.json` rather than `ClinicState`, per ADR-021's own consequence note; the editor is
ADR-082's composer card reused, which is what the user asked for in their first sentence and is why the
screen should read native rather than bolted on.

Glyph deliberately **reserved**, not guessed — ADR-093's lesson is to render the neighbours, and one
constraint is already known: a third box-shaped destination under `storefront.fill` and `server.rack` is
the thing to avoid, which handicaps `calendar.badge.clock` before the render starts. ⌘⌥A verified free.

## 2026-09-09 (later still) — Automations glyph: `alarm.fill`, decided at size and in adjacency

Ran ADR-093's comparison properly this time — twenty candidates at the row's real metrics (13 pt in an
18×16 box, 13 pt semibold label, 6 pt-radius pill, copied verbatim from `ScreenNavRow`), both states,
both appearances, and **stacked under `storefront.fill` and `server.rack` from the first render** rather
than after a single-column sheet had already misled the choice. Harness was a 90-line `swiftc` script
over SwiftUI `ImageRenderer` at scale 2 (real size, for judging) and scale 5 (for reading detail).

**Four candidates were excluded before rendering, on vocabulary the app has already spent** — and this
check should come before any contact sheet. `clock.arrow.circlepath` already means *recent* in Clinic:
the Diff panel's session scope and, more awkwardly, the Quick-starts pill on the very New Session screen
whose composer card the Automations editor reuses. Likewise `bolt` (ADR-094's Hooks chip),
`arrow.clockwise` (refresh), `sparkle`/`wrench` (Replay). Grepping `systemName:` across `Sources/` took
one command and killed the two glyphs I would otherwise have shortlisted first.

What only the adjacency view showed:
- **The box fault ADR-093 predicted is real.** `calendar.badge.clock` and `calendar.day.timeline.left`
  make a third rounded box under two rounded boxes and the block becomes one texture, not three
  destinations.
- **The alarm clock wins**: its two bell ears are a silhouette neither neighbour has, so it reads as a
  different kind of thing rather than a third variant of the same box.
- **`metronome` is `bolt.horizontal` all over again.** At 5× it is unmistakable and the most distinct
  silhouette in the set; at the real 13 pt it is an anonymous triangle. Judge at size — never scale a
  glyph up to admire it. The 5× sheet is for reading *why* something fails, not for choosing.

Recorded the residual cost in the ADR instead of waving it away: an alarm clock carries a mild
notification connotation and `bell.slash` is already Clinic's mute badge. Different marks, different
places, never adjacent — but if notifications ever earn a destination, that is the pairing to re-render.

**Addendum, same day — asked whether the block could be uniformly filled.** User: *"Is there a 'filled'
version of the server glyph?"* There isn't: SF Symbols gives `server.rack` no `.fill`, and `xserve`,
`xserve.raid` and `macpro.gen3.server` are all outline too. The other route to a uniform block *is*
available — drop Marketplace to outline `storefront` — so I rendered it instead of asserting, four
variants at real metrics in both appearances and states.

**It loses, and my stated hypothesis about why was right for the wrong reason.** I predicted outline
storefront would twin `server.rack` worse; what the render actually shows is more specific — ADR-093's
twin was "same rounded box, same mass, divided interior", and going all-outline makes the two share
*stroke weight* as well, the one axis that still separated them. `storefront.fill`'s solid mass against
`server.rack`'s bands is doing real work, clearest in dark mode.

The lesson worth keeping: **the mixed fill weight in that block is load-bearing, not an inconsistency.**
Anyone who "tidies" it will re-open the twin ADR-093 spent a render deciding. Recorded in ADR-095 so the
question doesn't get asked a third time.

**Correction, same day — `alarm.fill`, and the method error behind the first answer.** User chose the
fill. I had argued against it ("the ears merge, the face becomes a blob"), and **that claim was formed
on a vector re-rendered at 5× — the exact error I had just named in the `metronome` finding two
paragraphs earlier.** Judging a glyph at size means magnifying the *rasterisation*, not re-drawing the
vector larger.

So the harness gained the right technique, which is the thing to keep: render at the 2× the app really
draws at, take the `cgImage`, blit it into a context `zoom`× larger with `interpolationQuality = .none`.
What comes back is the actual pixels a 13 pt glyph gets, big enough to read.

Under that test `alarm.fill` holds: ears clearly notched off the body, face a clean knockout with
legible hands, feet intact, light and dark alike. And two arguments for it that I had missed entirely:
it is **crisper in the selected state** (outline `alarm`'s thin white stroke thins against the accent
fill; the fill's knockout face doesn't), and it **improves ADR-093's twin instead of being neutral to
it** — fill / outline / fill leaves `server.rack` as the only outline of the three, pushing it further
from `storefront.fill`. I had dismissed that rhythm as "odd" from the 5× sheet; at real pixels it is the
strongest argument for the choice.

Corrected the earlier entry in place rather than leaving a wrong record next to a right one.

## 2026-09-09 (later still) — Fixed the `done` state defect found while designing Automations

Landed the ADR-061 correction rather than leaving it in the backlog, because it is a live defect today.
`BackgroundAgent.isRunning` treated only `completed`/`failed`/`stopped` as terminal; the CLI actually
reports **`done`** with `status: idle` and the process still resident. Six user-visible consequences,
all of which had been shipping: the sidebar kept `moon.zzz.fill` on a finished agent, the row action
stayed *Attach* instead of *Open*, *Stop Detached Session* stayed on the menu, `RepoUpkeep` thought the
directory was still in use, `runningAgent(for:)` handed back a corpse, and — the expensive one —
`BackgroundAgentsService`'s backoff never engaged, so `claude agents --json --all` was spawned every
15 s forever after the first detached session instead of dropping to 60 s.

**A second hole, same root cause, that I only found by reading the caller**: `refresh()`'s announce
trigger list was `["needs_input", "blocked", "completed", "failed"]` — so ADR-061's promise that a
detached agent reaching completion posts a notification *never fired on a normal finish*. Worth the
habit: when a constant's contents turn out to be wrong, grep for every other place the same vocabulary
was hand-written. Fixed by hoisting all three sets onto `BackgroundAgent` (`terminalStates`,
`attentionStates`, `announcedStates`, the last derived from the first two minus `stopped` — a stop the
user asked for needs no telling), so running-ness and notify-ness cannot drift apart again. Same move as
`PluginComponents.groups` being keyed by `PluginKind`.

**The regression test is the CLI's verbatim payload**, captured during the probe, not a hand-written
fixture — the whole bug was that the real output does not match the documented shape, so a fixture I
wrote from the docs would have reproduced the error rather than caught it. Verified it actually bites:
swapped the old expression back in, watched it go red, restored, green. 210 tests pass; `make build`
succeeds.

**Committed, three commits, one per ADR.** The tree had been carrying *two* uncommitted features, not
one — ADR-094's marketplace filter as well as ADR-093's MCP screen — so "commit it all" was a split, not
a single commit. Checked separability rather than assuming it: `showingMarketplace` existed at HEAD only
in the four files ADR-093's set already contained, the Marketplace files never touched `window.screen`,
and the MCP files never touched `PluginKind`. Clean.

Then actually verified bisectability instead of claiming it, which is the part I nearly skipped: a
throwaway worktree at each intermediate commit with the gitignored xcframework symlinked in, `swift test`
(206 → 208 → 210, green at each) and a full `xcodebuild` at both. Both green; worktree removed.
`bb628c9` ADR-093, `840deeb` ADR-094, `04fc10f` the ADR-061 correction.

## 2026-09-09 (evening) — Automations built (ADR-095, commit 9831280)

All six backlog steps in one pass: `ClinicCore/Automations` (CronSchedule + presets, Automation/Run,
templates, launcher, run store, scheduler), the `--bg` launch path, `AutomationsModel`, the sidebar row
and ⌘⌥A, the screen with its gallery/detail and the ADR-082 composer card reused as the editor, and the
`clinic-wake` LaunchAgent behind its preference. 247 tests (was 210), app builds, smoke-run verified.

**Two things the build taught that no amount of design would have:**

- **Catch-up was 2.25 s per decision** for a week-stale `* * * * *`, because "what was the last time
  this should have run" stepped forward one fire at a time — on every wake, for every automation. The
  fix is a `lastDate(atOrBefore:)` that walks days *backwards*: O(days) whatever the expression,
  microseconds instead of seconds. Caught only because I gave the test a wall-clock bound rather than
  just asserting the answer. **Perf assertions in unit tests earn their keep when the slow path is
  proportional to something the test can make pathological.**
- **The first smoke run showed three of eight template tiles speaking raw cron.** `0 18 * * 1-5` is not
  one of the five presets, so `summary()` fell through to the expression. Fixed by phrasing weekday
  shapes ("Every weekday at 6:00 PM") *without* adding a sixth picker segment — the picker's vocabulary
  and the display vocabulary are allowed to differ, and conflating them would have been the wrong fix.
  A `noBundledTemplateShowsRawCron` test now makes the gallery's English a property of the templates.

**A design refinement worth recording:** completion is not a hook. `SessionEnd` never fires for a `--bg`
run and `Stop` is end-of-turn, so runs settle from the `claude agents` poll instead —
`BackgroundAgentsService` gained an `onRefresh` callback so one poll serves both readers. This is the
direct payoff of this morning's `done` fix; without it every run would have read as permanently
in-flight, which is exactly the bug that fix removed.

**Verification technique worth reusing:** rather than driving the UI to test the launch path, I built a
throwaway SPM package in the scratchpad depending on `Packages/ClinicCore` by path and ran the real
production code — argv, `AutomationRunner.launch`, `parseAgentId` — against the live CLI. It proved the
correlation design in production (short id `fbedf704` → session `fbedf704-e7dc-…`) in about a minute,
where a UI-driven smoke test would have needed synthetic clicks. Linking a bare `swiftc` binary against
SPM build products failed; a scratch package with a path dependency is the cheap way in.

Two Swift-6 details: the actor mutation closure in `AutomationRunStore.update` needs `@Sendable`, and
`Bundle.module` needs `resources: [.process("Resources")]` in Package.swift — the first resource
ClinicCore has shipped. Also `-ClinicScreenOnLaunch automations|marketplace|mcpServers` now lands a
smoke run straight on a screen, avoiding the synthetic-click problem entirely.

Not built, and said so in the ADR rather than left to be found: no Replay deep link from a run row, and
`keepRuns` is only enforced when auto-prune is on.

**Smoke instances share `UserDefaults` with the live app — amended ADR-038.** User asked to stop the
Claude Code credential prompt in smoke runs. The cause was not the prompt code: `CLINIC_APP_SUPPORT`
isolates state, sockets, chats and snapshots, but **`UserDefaults` is keyed by bundle id**, so a smoke
instance inherits the real app's stored usage consent (ADR-070), polls the Keychain on launch, and macOS
prompts because the smoke build's path is not in the keychain item's ACL.

`ClinicPaths.isSmokeInstance` now names the condition. The rule worth keeping: **anything that acts
outside Clinic's own container on the strength of a stored preference must check it first** — today the
usage poll and the wake agent, the latter because registering would install a real LaunchAgent pointing
at the installed app that outlives the test.

Proved the fix with the unified log rather than a screenshot, which mattered: SecurityAgent *was*
running after the fix, and a screenshot would have read as failure. The log showed the smoke pid never
called `SecItemCopyMatching` at all, and the call that woke SecurityAgent came from the **live app's**
5-minute usage poll. Attribute by pid before concluding anything from a system-wide symptom.

Side note for the dev loop: a debug build prompts for `Claude Code-credentials` on its own poll anyway,
because each build is a new binary at a DerivedData path the ACL has not seen. Different problem, same
dialog.

Also removed `ClinicPathsShim` from `AutomationWake` — it existed only to avoid importing ClinicCore,
and the smoke check made that import necessary anyway.

## 2026-09-09 (later) — The automation editor did not fit its sheet

User: *"The new automation dialog looks busted, the UI does not fit inside it."* It did not, and the
mechanism is worth keeping: **a SwiftUI sheet sizes to its content, so a child that refuses to compress
gets clipped rather than resized — and because the stack is centred, one over-wide row clips every other
row's leading text as well.** The dialog looked comprehensively broken when exactly one row was wrong.

The row: three `.fixedSize()` controls whose labels alone need ~650 pt, in a 620 pt sheet. Fixed by one
label-and-control pair per `GridRow`. A first attempt at *two* pairs per row only moved the problem —
`Grid` shares width between columns, so "Failures and stalls only" truncated while its neighbour did
not. Also swapped the prompt editor's `maxHeight` range for a fixed height: with a range it grew to fit
a long template prompt and clipped the final line halfway, so the text appeared to bleed into the chips.

**Measure before diagnosing.** The display is 1800 pt wide and the captured PNG 3600 px, so the sheet
measured 618 pt — proving `.frame(width: 620)` *was* being honoured and the content was overflowing it,
rather than the frame being ignored. Guessing would have sent me to the wrong fix.

**New smoke keys, both of which paid for themselves immediately:**
`-ClinicAutomationDraftOnLaunch <template-id|blank>` opens the editor without synthesising a click, and
`-ClinicFloatOnLaunch YES` puts every window at `.floating` and activates the app. The second exists
because two unrelated apps on this machine stole focus mid-capture and produced screenshots of *them* —
twice. A smoke run that can be photographed regardless of z-order removes a whole class of wasted round
trip.

**A real defect the screenshot exposed, unrelated to layout:** a project-scope template opened with the
target set to **Chat**, because this machine's fresh smoke profile has no projects and the gallery falls
back. A "Morning triage" prompt that says "this repository" would have run in the Chats scratch
directory and quietly been about nothing. `AutomationDraft.missingProject` now blocks Create and says
why. Worth remembering that an empty-state smoke profile surfaces fallbacks the real app hides.

## 2026-09-09 (later) — Automation editor, second pass

User: *"The spacings are inconsistent and UI elements could be bigger. Project picker could include
their icons."* All three were fair.

- **The spacings were inconsistent because nothing named them.** The sheet had accumulated 6, 8, 10, 14
  and 20 pt gaps, each locally reasonable. A private `Metrics` enum (section / row / inset / sheet /
  width / corner) makes a gap a decision instead of whatever the line above used. Cheap, and the kind
  of thing worth doing the first time a view grows past three rows.
- **Captioned sections did more than the spacing fix.** Four unlabelled blocks never said which control
  belonged to which idea; SCHEDULE and BEHAVIOUR cost two lines. Controls went to `.controlSize(.large)`.
- **A project's icon cannot go in a `Menu`.** macOS menu items render a title and a system image only,
  so `Image(nsImage:)` has nowhere to go — the picker had to become a popover. That turned out better
  anyway: 24 pt `ProjectIcon`, name, and abbreviated path, which is what actually distinguishes two
  projects whose folders share a name. Rows needed their own hover state; a list of plain buttons that
  do not light up under the pointer reads as disabled.

**Two smoke lessons.** A popover cannot be opened by a synthesised click, so it needed its own launch
key (`-ClinicAutomationPickerOnLaunch`) to be photographable at all. And the draft key was reading
`sessions.projects` synchronously at launch, before the transcript scan had found any — so every
screenshot showed the Chat fallback and I nearly "fixed" a product bug that was a harness bug. It now
awaits `initialScan`. **Seeding a smoke profile by copying the live `state.json` is the fast way to get
real projects and real icons on screen.**

## 2026-09-09 (later) — Placeholder alignment, and how to actually measure it

User: *"The placeholder text and input text on the prompt box of this dialog is not aligned at all."*
Correct. I had overlaid the placeholder on the **padded container** in a `ZStack` and nudged it with a
guessed `.padding(.top, 8)`. ADR-082 had already solved this for the New Session screen — the
placeholder rides *inside* the `TextEditor`, before any padding, offset only by the 5 pt
`NSTextContainer` line-fragment inset. **The lesson is not the 5 pt; it is that I re-derived a fix the
vault already had.** Copying the working view would have cost one grep.

**Verifying it took longer than fixing it, and the technique is the keeper.** Compare the placeholder
against the *same string typed*, and look at the ink bounding box, not just its first pixel. Two
confounds both look exactly like misalignment:
- the **focus ring** exists only in the empty state (`promptFocused` is true when the prompt is empty),
  adding ink at the card edge;
- the **caret** sits at the text origin, taller than the glyphs and ~3 px to their left.
Naively measured, the empty state therefore reads as starting higher and further left. **The tell was
the right edge of the ink box, which matched from the first measurement** — same string, same font,
same width, so a genuine offset would have moved both edges. Once the crop excluded the caret the boxes
were identical at every threshold.

**Two smoke-harness fixes this forced, both worth keeping:**
- `-ClinicFloatOnLaunch` now re-asserts level *and activation* on a loop for 20 s. A fullscreen app
  (Discord) took over its Space mid-capture and the screenshot contained no Clinic at all.
- It also **pins the window origin** to (80, 80). Smoke windows land wherever the restored frame puts
  them, so two runs photographed for comparison did not line up and cross-image pixel coordinates were
  meaningless — the instability this log already warned about, now removed rather than worked around.
- `screencapture -l <windowID>` fails here ("could not create image from window") even though
  `CGWindowListCopyWindowInfo` happily returns ids, so full-screen capture plus a pinned, floating
  window is the only reliable route on this machine.

## 2026-09-09 (late) — CI had been red for five pushes and I had not looked

User: *"Looks like we have failing CI tests."* It had been failing since the automations commit —
**five consecutive red runs that I pushed straight past.** Local `make test` green is not the same as
CI green, and the gap between them is exactly the class of bug worth catching. **Check `gh run list`
after pushing; it costs one command.**

Two distinct problems, and the interesting thing is that both were *tests asserting the wrong thing*
rather than product bugs.

**1. A test that pinned Foundation's typography.** `weekdayShapesArePhrasedNotPrinted` asserted the
rendered time as a literal, `"Every weekday at 8:30"`. `en_US_POSIX` renders `.short` as **12-hour on
this machine and 24-hour on the CI runner** — so the test was about ICU, not about the phrasing it
exists to check. Now it builds the expected time with the same formatter and is parameterised over a
12-hour and a 24-hour locale, so the difference is *covered* rather than tolerated. Confirmed the guard
is not vacuous: en_US_POSIX → "6:00 PM", en_GB → "18:00".

Note that I had already been bitten by rendering once today (the U+202F narrow no-break space) and
"fixed" it with `hasPrefix`, which merely moved the hardcoding earlier in the string. **The general rule
is: never assert a formatter's output; assert your own text and derive the formatter's part.**

`CronSchedule.summary` also had a fallback that silently changed format — it built a date from bare
hour-and-minute components, and on the nil path rendered 24-hour where the formatter renders 12-hour.
A failure there would not have looked like a failure, only like a different time format on some
machines. Now it builds a complete date and pins the formatter's calendar and time zone.

**2. A flake that was always wrong, not newly wrong.** `snapshotWritesNothingIntoTheRepository`
(ADR-080, not mine) required the file count under `.git/objects` to be *exactly* equal before and
after. Git may pack loose objects or write a commit-graph between the readings, which **lowers** the
count without anything having been added — CI saw 4 then 3. Equality was never the claim; "adds
nothing" is. Now `<=`, plus the direct form: `git cat-file -e <tree>` in the user's repo must fail.
Checked that probe distinguishes a present tree (exit 0) from an absent one, so it is not vacuous.

Also worth knowing: the red runs finished in ~1–2 min because they bail at Core tests before the
expensive Ghostty build, while a green run is ~8 min. A fast CI failure is not a cheap one.

## 2026-09-09 — Session status indicators (ADR-096)

The state dots stopped saying "state". `StateGlyph` painted `working` **and** `unread` in
`Color.accentColor` — the same colour as the selection fill under them, the active panel icons, the
selected tab chip and the drop indicator. On this machine the accent is *red*, so a working session
and a selected row were the same red. Worse, the palette meant something different on every machine,
because it is a System Settings choice.

Fixed by picking a vocabulary and writing it down (ADR-096): **motion carries "running", colour is
spent only on the states that want the user.** `working` is a 0.7 arc turning once a second;
`launching` the same arc in `.secondary`; waiting is an orange dot that breathes; `unread` blue,
`idle` grey, `exited` a hollow ring. Nothing is the accent any more, including the attached
`moon.zzz`, which went `.secondary` to match the background-agent moon beside it.

Two things I only got right because I looked:

**The working arc must take no colour of its own.** My first instinct was `Color.primary` for the
neutral spinner. That is near-black in light mode and would have vanished into a selected row's
accent fill. `AnyShapeStyle(.foreground)` inherits the row's label colour instead — the same trick
ADR-077 used for the hover actions. I checked it in a harness built around a real `List(selection:)`
rather than a hand-painted fill, because the question *is* whether SwiftUI's selection styling
reaches a Shape: it does, focused and unfocused both.

**The first pulse made the most important state the faintest.** Scale 0.68 / opacity 0.55 at the
bottom of the swing left the orange "needs you" dot smaller and dimmer than the idle dot next to it,
for half of every cycle. Shallowed to 0.85 / 0.7. A screenshot caught this; reasoning about it
would not have, because you write the numbers thinking about the *peak*.

Also flipped the precedence: `StateGlyph` switched on `unread` before `state`, so a session that had
started working again still showed the stale unread dot. Live state first now, in the menu bar too.

Method note: a throwaway SwiftUI app that `sed`s the two shape structs straight out of
`SidebarView.swift` is a cheap way to iterate on a 10 pt glyph — no seeded smoke instance, no live
session in five states. Copying the source verbatim is what makes it honest; a hand-retyped copy
would have proved nothing about what ships.

## 2026-09-09 (night) — Notification sounds: your own files, in rotation (ADR-097)

User asked for local audio files as the notification sound, round-robin over several, and a way to
test it from Preferences.

**The hard constraint is `UNNotificationSound`.** It can only name a file in the app bundle or
`~/Library/Sounds`; an arbitrary path cannot be handed to it. Copying user audio into
`~/Library/Sounds` to work around that would be Clinic writing outside its own container for a
cosmetic preference, so instead Clinic plays custom files itself (`AVAudioPlayer`) and posts the
system notification *silent*. It can always do this: it is by definition running at the moment it
posts.

**The cost is Focus**, and it is worth naming rather than discovering later: a system notification's
sound is suppressed by Do Not Disturb, an `AVAudioPlayer` is not. Kept the empty-list default
routing through the system, so the behaviour only changes for a list the user built on purpose.

**Two sound paths existed and neither was chosen by the user.** One boolean drove
`UNNotificationSound.default` on the system path and `NSSound(named: "Ping")` in-app. Both now go
through one `NotificationSoundPlayer`, which is the only thing that decides whether a notification
makes a noise; `TabStore.notify` plays nothing itself.

**Missing files fall back rather than going quiet.** A rotation entry whose file has moved is
skipped; if *every* entry is missing the caller gets `.systemDefault`. A notification nobody hears
is indistinguishable from a notification that never fired, which is the one failure this feature
must not introduce.

**Smoke method.** Seeded the list by writing the JSON straight into the real defaults domain as
`-data` hex and launching a smoke instance against it (deleted the key afterwards — `CLINIC_APP_SUPPORT`
does not isolate `UserDefaults`). Verified the rotation end-to-end by streaming the unified log
while clicking Test Notification: `chime` then `ding`, i.e. it skipped the deliberately-missing
third entry. `log show --debug` shows nothing for debug-level messages; `log stream --debug` does.

Also: `move(fromOffsets:toOffset:)` comes from SwiftUI, not the standard library, so ClinicCore had
to spell it out — first compile error of the change, and a fair reminder of where that module's
Foundation-only line sits.

## 2026-09-09 (night) — `-w` never worked, and our own hook was why (ADR-098)

"Trying to create a new session with a worktree failed." No transcript, no tab, nothing in the unified
log — the CLI had died before a session existed, which was itself the clue: the failure was upstream of
anything Clinic writes.

Reproduced by replaying the exact launch line into a scratch repo. `claude --session-id X -w probe -p …`
worked. The same command plus Clinic's own `--settings ~/Library/Application Support/Clinic/hooks.json`
failed with *"WorktreeCreate hook failed: hook succeeded but returned no worktree path"*. The difference
was one line of our own JSON.

**`WorktreeCreate` replaces `git worktree add`; it does not report it.** ADR-027 installed every event
Clinic could name on the assumption they were all notifications. For this one, registering a command hook
means *you* create the worktree and print its path. `clinic-hook` forwards and prints nothing, so from the
CLI's side we claimed the job and produced an empty answer. Every `-w` launch Clinic has ever made was
broken this way.

Removed the event (ADR-098). Re-ran the same command with an otherwise identical settings file and the
worktree appeared — and the hook log showed `SessionStart` already carrying the *worktree* path as its
`cwd`, which is the signal the `WorktreeCreate` branches in `TabStore` were reaching for anyway. So the
removal costs nothing: `SnapshotService` resolves the repo root from each event's own `cwd`.

The lesson is narrower than "test your hooks": an event list is not a menu of notifications. Two of the
CLI's hooks are *overrides*, and registering one silently converts a listener into an implementation.
`LaunchTests` now asserts `WorktreeCreate` is absent, so the next "register everything" edit fails a test
rather than a launch.

Note for the next debugging session: Clinic writes `hooks.json` at startup, so a changed hook set needs an
app restart, not just a rebuild.

## 2026-09-09 (late) — the file tree's rows were never the thing you were clicking (ADR-099)

"The touch targets/responsiveness of items in the filetree of the 'files' tab is not very good."
One cause, four symptoms. `OutlineGroup` hands its content closure a view sized to its *own* label,
so `.contentShape(Rectangle())` on a `Label` shaped the label: the hit area of `Models.swift` was
about 110 pt of a 195 pt column, and the rest of the row was dead. Directory rows had no tap
handling at all — only the 12 pt triangle. Expansion lived inside the outline view where neither the
FSEvents rebuild nor "reveal the file I just opened" could reach it. And a PR's tree arrived
collapsed, which is the worst possible default for a list containing only the files that changed.

Fixed by flattening: `FileTreeNode.rows(_:expanded:)` in ClinicCore produces `[FileTreeRow]` and the
view is a `ForEach` of `FileTreeRowView` — a `Button` whose label fills the row, with the fill and
the hit shape as the same rectangle. Flat rows are the enabling move for all four: they are what let
a row be full-width at all, and they put expansion in the model, where `open` can union in
`ancestors(of:)` and a `ScrollViewReader` can scroll to it.

**`ancestors(of:)` is every path prefix, not a walk of the node graph** — that is what makes reveal
work on ADR-091's *compressed* tree, whose folded row keeps the deepest path as its identity. Worth
remembering: a fold that renames a row is fine as long as its id stays prefix-addressable.

**macOS `List` cannot be made dense.** It inserts ~8 pt of row spacing, `listRowSpacing` is
`unavailable` on macOS, and `listRowInsets(EdgeInsets())` does not touch it — a 24 pt row drew at a
32 pt pitch. Measured 64 px vs 48 px at 2× in a throwaway harness built from the real source files
(the trick from [[clinic-smoke-instances]], and it paid for itself again — three layout questions
answered in two screenshots without seeding a session). Switched to `ScrollView` + `LazyVStack`.

**Also found while in there**, both invisible until you look: `PRFilesView.tree` rebuilt the node
tree, ran the single-child fold and rebuilt the stats dictionary *inside `body`*, with the fuzzy
filter re-ranking 300 paths twice more — on every selection and every keystroke. And
`FileTreeNode.build` ran on the main actor over a 50 000-entry index on every FSEvents burst. Both
moved: the first into `PRFilesModel`, the second into a detached task.

**Verification.** Added `-ClinicPRPaneOnLaunch files` rather than synthesising a click into the tab
strip — a smoke hook is cheaper and more honest than a coordinate. Then the one thing a screenshot
alone could not prove: a guarded synthetic click 110 pt to the *right* of the `impl` folder's name
in Campfire #1069 collapsed it. That is the gesture that did nothing before.

Keyboard navigation is deliberately still missing; it needs the tree to hold focus beside a live
terminal surface, which is its own decision (noted in ADR-099).

## 2026-09-10 — the diff scrolled badly because every row was four selectable Texts (ADR-100)

"The Diff view still feels like its not scrolling smoothly. For comparison, when viewing files in the
files tab it feels good." *Still*: [[ADR-080 Diff Panel]] had already fixed how much the panel
**built** per frame by flattening the diff to one row per line. What was left was what each visible
row **costs**, which virtualisation cannot touch.

**Measured before deciding anything.** A throwaway harness (the scratchpad trick from
[[clinic-smoke-instances]]) with `DiffScrollView` copied verbatim, a real 7,524-row patch, a
timer-driven scroll and main-thread CPU per frame. Release build, per frame at 40 pt / 80 pt:

| shape | 40 pt | 80 pt | over 16.7 ms @ 80 |
|---|---|---|---|
| today | 10.6 ms | 19.4 ms | 637/900 |
| selection only on the code `Text` | 5.7 | — | — |
| no per-row selection | 3.7 | — | — |
| one `NSTextView` | 1.7 | 2.0 | 1/900 |

**`.textSelection(.enabled)` costs ~35 µs per selectable `Text`, and every row had four of them** —
two line numbers, the marker, the code — for selection that could never span a row anyway. Moving
the modifier to the environment changes nothing; the cost is per `Text`. Pinned headers were another
~1 ms; `scrollTargetLayout`, the visibility callback and the horizontal axis were noise.

The number that decided the *shape* rather than the size of the fix: **SwiftUI's cost scales with
scroll speed** (10.6 → 19.4 as the step doubled) because it is paid per row materialised, while the
text view is flat. Trimming could reach ~5 ms; it could not make a flick free. And the comparison in
the complaint was exact — the Files pane is already an `NSTextView`.

So the body is now one text view (ADR-100), and the shipping code measures 2.2 / 2.3 / 3.4 ms at
40 / 80 / 160 pt per frame. `DiffDocument` in ClinicCore holds the text plus per-line metadata;
uniform line height makes every geometry question integer arithmetic (`y / lineHeight`), the
vertical counterpart of ADR-080's `columns × advance`.

Four things cost a round each and are worth remembering:

- **`NSTextView` sizing itself is a full-document layout.** With `isVerticallyResizable`, building a
  7,580-line page took **222 ms**; with it off and the frame set arithmetically, **14 ms**.
- **AppKit does not inset the clip view for an `NSRulerView`** (macOS 26, and `tile()` does not help
  — measured `clip.frame == scroll.frame` either way). The gutter is therefore an overlay and the
  text is inset past it with **`textContainerInset`**. A paragraph head indent is *not* equivalent:
  fragments laid out at x = 106 drew their runs shifted left, under the gutter — which looked
  exactly like a horizontal scroll offset and sent me hunting the wrong bug.
- **`drawHashMarksAndLabels(in:)`'s rect is not in the ruler's coordinates.** `rect.fill()` painted
  over the entire window — every glyph in the app vanished, including SwiftUI's. Fill `bounds`.
- **`NSString.draw(at:)` per number costs 1.8 ms a frame** at 55 visible lines; it builds a layout
  per call. One attributed string with right-aligned tab stops, drawn once, is ~0.2 ms.

Also: the highlighter now returns `[DiffToken]` (range + colour) instead of an `AttributedString`
per row, which is what a text storage wants and is cheaper across the actor hop. `DiffScrollView`,
`DiffRowView`, `DiffLineView` and the unused `DiffView` are gone; the PR panel's Files tab renders
through the same body, so there is one diff renderer in the app.

Verified: 264/264 core tests (7 new for `DiffDocument`), the real view screenshotted in a harness
built from the shipping source, and the real app on a smoke instance — working-tree scope, 19 files,
`smokeCollapseAll` at 49 ms for the lot.

## 2026-09-10 (later) — the Diff panel gives up its continuous scroll (ADR-101)

"I'm now thinking that the continuous file scrolling of the diff view might not be the best pattern.
Instead we should use the same pattern as the diff/file viewer on PRs and add a collapsable file tree
to the left and have it view one file at a time."

[[ADR-080 Diff Panel]] had considered exactly this and chosen the other branch; [[ADR-091 Pull Request Panel Tabs and Files Tree]]
then went the other way for the same question a month later. Two surfaces answering *what changed?*
in two different shapes was the real defect, so ADR-101 makes them one: `DiffBrowser` +
`DiffBrowserView` in the app target, with the PR tab and the Diff panel as thin wrappers that only
supply where the diff comes from and what to say while it is not there yet.

**The merge came first, and it was the right call to ask.** ADR-099's flat file-tree rows were sitting
unmerged on `worktree-indexed-purring-crystal`, and they are exactly the substrate this needed
(expansion in the model, full-width row targets, `FileTreeNode.rows/compress/directories`). Building
the diff tree on main's `OutlineGroup` would have shipped the hit-target bug ADR-099 had just fixed
and left two versions of the same tree to reconcile. Merged it (one conflict, in `PRFilesView`,
between their tree and ADR-100's viewer), then built on it.

**Parking someone else's work to merge.** The tree carried an unrelated, partly *staged*
notification-sounds change, and git refuses a merge with a dirty index even for files the merge does
not touch. `git stash push -- <paths>` for exactly those eleven files, merge, `git stash pop --index`,
then verified `git status --porcelain` was byte-identical to before and the restored diff matched a
patch taken beforehand. Worth doing in that order every time: the backup patch costs nothing and the
comparison is what makes "I did not lose your work" a fact rather than a hope.

**What the new shape deletes is most of what ADR-080 built.** The rail and `DiffFileSummary`; the
20,000-row line budget, `DiffPage.fileLimit`, the "Show more" footer and the row cache; per-file
collapse; and — from ADR-100's body — the in-text file headers, the click-to-collapse hit test and
the floating header. One file at a time bounds row building and highlighting by construction, so the
budget had nothing left to protect. `DiffPage` is now just the flattening, and `DiffDocument` is one
file's lines.

**One thing worth keeping in `DiffBrowser.show(_:)`**: the Diff panel reloads on every FSEvents burst,
which the PR tab never does. So the tree is rebuilt only when the *set of paths* changes, the
expansion set gains only directories that are genuinely new (a folder the reader closed stays
closed), and the selected file re-renders when its *content* changes — `rendered` holds the whole
`UnifiedDiffFile`, so a working tree moving under the reader repaints and a re-selection of an
unchanged file does not.

Verified on smoke instances: the Diff panel on working-tree scope (21 files, tree, selection via a
new `-ClinicDiffSelectFile` hook that replaces `-ClinicCollapseAllAfterLaunch`), and the PR panel's
Files tab against live PR #32 of `livewire` — 47 files, folded directory chains, first file selected.
That second one needed `-ClinicOpenPRPanelOnLaunch`, added here: the PR pane was reachable only by
clicking the footer chip, which is what drove the synthetic-click work on 2026-09-09. Seeding recipe
from [[clinic-smoke-instances]] — and note `state.json` dates are decoded with `.iso8601`, which
rejects fractional seconds, so a seeded state with microseconds silently loads as empty.

265/265 core tests; `DiffRowsTests` and `DiffDocumentTests` rewritten for the smaller types.

Follow-up the same day, from a look at the shipped panel: *"there is now a vertical divider to the
right of the turn/selection controls that bleeds into the search bar and the file title bar… another
bug is that the line numbers scroll above the file name bar."*

**Both were the same bug: an `NSRulerView` draws outside its bounds and nothing clips it.** The
"divider" was AppKit's own ruler chrome — a hairline down the *client view's* whole length, and the
client is a 128,000 pt text view — so it painted up across every header above the scroll view. The
line numbers were the same spill downward-adjusted: the topmost visible line is drawn at a *negative*
y whenever it is half scrolled (`first = floor(visible.minY / lineHeight)`), which without a clip
lands on the bar above. Fixed by doing all the drawing in `draw(_:)` without calling `super`, with
an explicit `NSBezierPath(rect: bounds).setClip()` and `clipsToBounds = true`. Worth remembering as a
rule: **a ruler view is a sibling of the clip view, so it is outside everything that clips.** It is
the same lesson as the `rect.fill()` that painted over the whole window earlier — that rect is not in
the ruler's coordinates either.

Took the headers back to the drawing board while in there (ADR-101 amended): the browser's chrome is
now a header *per column* — filter over the list, path + status + counts over the diff — with the
drag divider running the full height between them, instead of two full-width rows stacked above both
columns. That also gave the `renamed` chip somewhere to live; the tree's A/D badge cannot say it, and
it had been carried by the in-text file header this change deleted.

Verified both states of the toggle and both surfaces (Diff panel, and the PR Files tab against live
PR #32), scrolling with a guarded `CGEvent` poster — frontmost-pid and window-bounds checks from
[[clinic-smoke-instances]] — because a short file cannot reproduce a scroll bug. Deleted
`ClinicDiffShowTree` from the real defaults domain afterwards: a smoke run wrote the new key even
though its value matched the default.

Third pass the same day: *"the code can horizontally scroll to expose the padding for the line
numbers, this is kinda jarring."* True, and the arithmetic said so plainly: `textContainerInset` is
**symmetric**, and `resize()` was sizing the text view's frame with it *twice*
(`(gutterWidth + leftPadding) * 2`). The gutter's width belongs on the left only — it is what the
overlaid ruler sits on — so the second copy became a gutter-wide void past the end of the longest
line, and the reader could scroll out into it. Measured on the panel's own diff:
`columns=125, advance=7.418` gave `width=1045.2` after the fix against `1139.3` before — **94 pt of
scroll into nothing**. Now `textInset + columns × advance + trailingPadding`, with a deliberately
small 12 pt trailing margin so the longest line is not flush against the edge.

Verification worth copying: a screenshot could not settle this one, because the longest line in a
file is usually off screen, so "there is blank space on the right" looks identical whether the
content width is right or wrong. Logged `columns`, `advance` and the resulting width from `resize()`,
checked the arithmetic, then removed the probe — the rule from [[clinic-smoke-instances]] that a
screenshot proves a view renders, not that a number is right. Horizontal scrolling in the smoke
instance needed `wheel2` on the `CGEvent` scroll poster (`wheelCount: 2`), which is now in the
scratchpad tool alongside the vertical case.

Fourth pass, and the first fix made it worse: *"Its still sliding out more and now by default is not
left aligned to start with."* The width arithmetic had been right and the *shape* wrong. Four things,
in the order they matter:

- **The gutter was an overlay on top of the scrollable text**, with the text inset 106 pt to clear
  it. So the document carried a gutter-wide dead margin at its left, and scrolling sideways slid the
  code *underneath* the numbers. It is now a sibling view beside the scroll view (`DiffGutterView` in
  a `DiffBodyView` container): the code's scrollable area simply begins where the gutter ends, which
  is what an editor does and what `NSRulerView` could never give (AppKit does not inset a clip view
  for a ruler — the finding from the pass before).
- **The content width was a guess.** `columns × advance` holds only for plain ASCII; a tab, a CJK
  character or an emoji renders wider, and any line the guess underestimates extends past the
  scrollable width and *cannot be reached* — "sliding out more". Now the widest four lines (ranked by
  character count, which a monospaced font makes a good proxy) are measured with the real font and
  paragraph style. Four measurements per document, exact for any content.
- **Horizontal elasticity is off.** A sideways swipe on a diff that does not need scrolling used to
  rubber-band the code away from the numbers and spring back, which reads as a glitch in a column of
  code rather than as physics. Vertical elasticity is untouched.
- **The gutter is sized to the digits the file needs**, not a fixed 100 pt: 80 pt for two-digit line
  numbers, which is 20 pt of code back in a 380 pt panel. A fixed gutter reads as the code being
  pushed off the left edge — the likeliest thing behind "not left aligned to start with".

Lesson worth keeping: **when a fix makes it worse, the arithmetic was not the bug — the structure
was.** Two rounds went into computing the right width for a layout that should not have had the
gutter inside the scroll view at all.

Same day, closing the loop: *"Can we apply the same visual improvements to the files / editor panes.
These share similar layouts and should share or be as similar as possible for their features."*

Three panes put a list beside a detail view — Files, the PR panel's Files tab, and now the Diff panel
— and ADR-099 had already unified their *rows*. Everything around the rows had drifted: the Files
tree header had no material and a project name where the others have a filter, its detail header was
30 pt against the others' 28, its tree toggle sat mid-pane in the *detail* header, and the two seams
were different views with different clamping. Two headers of different heights side by side is
exactly what makes two columns stop reading as one pane.

`PaneChrome.swift` now holds `PaneHeader`, `TreeToggleButton`, `TreeFilterField` and
`TreeSplitHandle`, and all three browsers use them (ADR-102). The Files tree gained the inline
filter, ranked with the same `FuzzyMatcher` Quick Open uses — Quick Open stays as the keyboard path
and its button moved to the trailing actions. The toggle now lives at the pane's **top-left in both
states**, which keeps ADR-081's "it can never hide itself" and adds "it does not move when the list
opens".

Two things worth remembering:

- **A `str.replace` that does not match is a silent no-op.** The `reloadTree` I patched to cache
  `paths` for the filter was the pre-merge body; ADR-099 had rewritten it to build the tree in a
  detached task, so the edit did nothing and the filter reported `0/0` with every file present. The
  screenshot caught it; the build could not. Patch scripts now assert the anchor exists before
  replacing.
- **Driving the UI needed a click-and-type poster**, built beside the scroll one and guarded the same
  way. The first attempt typed into the *terminal*, because `screencapture -l` images start at the
  window's origin and the window sits at y=39 — window-image coordinates are not screen coordinates.
  With that fixed, "chrome" in the Files filter gives `2/174` and the two expected hits.

Cleanup afterwards: the toggle click wrote `ClinicEditorShowTree=0` into the *real* defaults domain
(`CLINIC_APP_SUPPORT` does not isolate `UserDefaults`), and `ClinicEditorTreeWidth` had moved from
293 to 230. Deleted the first (the user never set it) and restored the second.

Two follow-ups on the shared chrome (ADR-102 amended):

**The seam looked broken because it was 9 pt of layout.** `TreeSplitHandle` was a hairline centred in
a 9 pt transparent strip, so between two columns that each paint their own background sat 8 pt of the
*pane's* background — a gap with a faint line in it rather than an edge. It is now one point of
layout: a `separatorColor` line the columns meet at, with the 11 pt grab area as an overlay, which is
wider than its parent and still hit-tests (worth knowing: a SwiftUI overlay is not clipped to the
view it hangs off, so a thin control can have a fat target without taking the width).

**The Diff panel's resize was jittery because the column was not reading the drag.** The handle wrote
a live `@State`, but the column's frame read the *stored* `@AppStorage` width, which only changes on
commit — so nothing moved during the drag and the column jumped at the end. The Files panel had it
right and the port lost it. The column now reads the live value and falls back to the stored one
before the first drag.

Verified by reading the number back rather than by eye: a guarded `CGEvent` drag poster (down, twelve
moves, up — same frontmost/window guards as the scroll and type posters) moved the diff seam +60 and
`ClinicDiffTreeWidth` went 278 → 338; the Files seam +50 took `ClinicEditorTreeWidth` 213 → 263. Both
restored afterwards, along with `ClinicEditorShowTree`, which a smoke run keeps writing into the real
domain — `CLINIC_APP_SUPPORT` does not isolate `UserDefaults`, so every run that touches a pane
preference needs the check.

**Landed.** Two commits, pushed to `origin/main`:

- `f9cb056` — ADR-101 + ADR-102 (the browser and the shared chrome, plus the diff body's gutter,
  measured width and elasticity fixes).
- `eb8f23a` — the notification-sounds work (ADR-097) and the `WorktreeCreate` removal (ADR-098) that
  had been sitting uncommitted in the tree from an earlier session, committed unchanged.

`ClinicApp.swift` held hunks from both, so it was split at the hunk level (`git apply --cached` of a
filtered patch) rather than letting one commit swallow the other's work. Worth doing whenever a
shared file straddles two changes: the split is a minute's work and the history is worth more than
that. Verified before committing — 265/265 core tests and a clean app build with everything applied —
and the earlier commit was checked by inspection to hold together on its own (its `ClinicApp.swift`
references only symbols that exist at that commit).

## 2026-09-10 — File browser chrome sized to be hit (ADR-103)
User: *"The UI for the files/diff file tree (collapse/expand action, filter box, etc) are a bit too
small and difficult to see sizing wise."*

ADR-102 settled which controls the three file browsers share and where they sit; nothing had ever
sized them, so the whole chrome was still at the panel's caption scale. Wrote
[[ADR-103 File Browser Chrome Is Sized To Be Hit]] and implemented it:

- `PaneHeader` 28 → 34 pt, and `.controlSize(.small)` off both headers.
- New **`PaneIconButton`**: a 24 × 24 pt target, 14 pt glyph, hover/on fills in the same rounded
  language the rows use. Every header verb now takes it (tree toggle, Collapse All, Show Hidden,
  Quick Open, pop-out, Reveal). The old bare `Image` in a `.borderless` `Button` hit-tested as the
  glyph — the header's version of the fault ADR-099 fixed in the rows.
- Show Hidden swaps `eye`/`eye.slash` rather than only its tint.
- `TreeFilterField`: 24 pt tall, 12 pt text, focus border, `matches/total` at 11 pt — and the whole
  capsule takes the click and gives focus (a `.plain` field is only as tall as its text).
- Rows: 24 → 26 pt, name 12 → 13, chevron 9 → 10.5 in a 14 pt column, subtitle/glyph/indent up;
  selected row goes semibold at a 0.20 fill.
- `TreeSplitHandle` paints accent while hovered or dragged.
- The Diff panel's scope bar became a `PaneHeader` — it was a third bar of a third height.
- Quick Open moved to the end of the trailing group so it stops shifting when a file opens.

**Verified** by sed-ing the real `PaneChrome.swift` / `FileTreeRowView.swift` / diff accessories out
at `HEAD` and at the change into two throwaway SwiftUI apps and screenshotting them side by side
(the ADR-096 technique) — same rows, same data, before and after. Then confirmed in the real app with two smoke runs against this
worktree — the Files panel (`-ClinicOpenEditorOnLaunch` on `PaneChrome.swift`) and the Diff panel
(`-ClinicOpenDiffPanelOnLaunch -ClinicDiffScope workingTree`), the latter showing the scope bar and
the browser's two headers as one band at last. Smoke instances quit by pid-with-`clinic-smoke`-env;
the first run wrote one `NSWindow Frame main-AppWindow-1` key into the real domain, restored by hand,
and the second wrote nothing.

`screencapture` returned "could not create image from window" for ~15 minutes mid-session, for
windows it had captured minutes earlier and for plain `-R` rects too, then recovered on its own —
worth probing with `screencapture -x -R 0,0,100,100` before concluding a window is unreachable.

`swift test --package-path Packages/ClinicCore` — 265 tests pass. Build clean.

## 2026-09-10 (cont.) — Panel tabs fit the panel (ADR-104)
User: *"Can we also take a pass at improving the tabs/tab bar for the right panel?"* — and punted a
density preference to later, so ADR-103's "not doing" stands.

ADR-079 built the panel strip from `TabChip`'s metrics so both strips would read alike; the trouble is
the session tab bar spans the window and the panel strip spans a 380–520 pt column. Wrote
[[ADR-104 Panel Tabs Fit The Panel]] and implemented it:

- **`ViewThatFits`** over labelled chips → compact glyph-only chips → compact chips in a `ScrollView`.
  It falls through to the *last* candidate when none fit, which is what makes scrolling the backstop
  rather than the default. Three labelled chips need ~320 pt; six compact ones fit 320.
- **The bug the harness caught:** a chip's `maxWidth: 200` is a *cap*, but in a definite-width strip
  every chip stretches to it — three tabs measured 340 pt to `ViewThatFits` and drew 600, overflowing
  the panel. `.fixedSize(horizontal: true, vertical: false)` on the row. Invisible in the session tab
  bar, where the enclosing `ScrollView` proposes unbounded width.
- **Every chip gets a resting fill.** Before, only the selected tab was a chip and the others were
  bare glyph+label; in the compact form a glyph with no chip is just a toolbar icon.
- **`PaneIconMenu`** (ADR-103's button shape with a menu behind it) for the `+`, listing open panes as
  well as addable kinds — so it doubles as the compact strip's overflow list and never disables. The
  old one greyed itself out once all five kinds were open.
- Selected tab scrolls into view; glyphs get two sizes (`PRStyle.glyphSize.tabCompact`).
- A compact chip has no close ✕ on purpose — an ✕ over the glyph on hover puts a destructive target
  under a pointer that came to select.

**Verified** with a harness rendering the real strip source at 320/380/430/560/760 pt × 3/4/6 tabs
(this is what caught the stretch bug), then in the app at 430 pt and at the 380 pt floor.
`swift test --package-path Packages/ClinicCore` — 265 pass. Smoke runs wrote `ClinicEditorShowTree`
and `ClinicPanelWidth` into the real domain; both restored.

## 2026-09-10 (cont.) — The vault moved into the repo (ADR-105)
User: *"We've been tracking the documentation of this project in our obsidian vault. Let's move this
vault into the project so we can track it with source control."*

[[ADR-012 Process]] had pinned the vault at `~/SoftwareProjects/vaults/clinic`, so this needed
[[ADR-105 The Vault Lives In The Repo]] rather than a quiet `mv`. 104 ADRs and 1500 lines of log had
no history; now a commit can carry its own reasoning.

- `~/SoftwareProjects/vaults/clinic` → `clinic/docs`, contents unchanged, so `docs/` is the vault root
  and every wikilink still resolves. Old path removed (user's call); re-open the vault at `clinic/docs`.
- `docs/.obsidian/` gitignored — `workspace.json` alone changes on every pane you open.
- ADR-012 marked `superseded by ADR-105` with the process half left standing; Design Tree's Process
  node points at the new ADR.
- Path updates: `CLAUDE.md` (both "before changing anything" lines, plus `docs/` in Layout),
  `README.md` (a Documentation section, since the repo is public), [[Repo Layout]]'s tree.
- `project.yml` lists explicit source paths, so no target picks `docs/` up.

## 2026-09-10 (cont.) — The Images panel became a viewer (ADR-106)
User: *"The image/attachments side panel needs some UX help. When viewing images its impossible to
resize/zoom/or otherwise adjust the viewer making it difficult to inspect images"*

[[ADR-056 Session MCP Tools]] had specified the panel in one sentence ("a gallery and a lightbox")
and that is what existed: a 160 pt thumbnail grid over a fixed `.sheet` with `scaledToFit`. No zoom,
no pan, nothing resizable, no 1:1 — and `NSImage(contentsOfFile:)` called inside the view body for
every attachment on every render. Wrote [[ADR-106 The Images Panel Is A Viewer]] and implemented it:

- **List-then-detail in the shared chrome** (`PaneHeader`, `TreeToggleButton`, `TreeFilterField`,
  `TreeSplitHandle`), assembled the way `DiffBrowserView` assembles it — the fourth browser to get
  its chrome by *using* ADR-102's pieces rather than copying a header. `ImagePrefs`
  (`ClinicImagesShowList` / `ClinicImagesListWidth`), pane minimum 400 with the list and 280 without,
  `renderKey` carries the flag. ⌘⌃E generalised to "the front browser's list" (`toggleBrowserList`),
  binding identifier unchanged.
- **Zoom in device pixels per image pixel**: 100% = one file pixel on one display pixel, document
  view sized in *pixels*, `magnification = zoom / backingScale`. Fit never exceeds 100%, and re-fits
  on every `layout()` so the image follows the divider and the window. `−`/`+`/percentage menu/fit in
  a footer bar, `+ - 0 1`, double-click, ⌘/⌥-scroll about the pointer, pinch, drag-to-pan, arrows,
  ⌥↑/⌥↓ through the gallery. Nearest-neighbour past 150%.
- **Image windows** (`ImageWindowController`), one per path, opened at the image's own size — the
  ADR-081 pattern, and the actual answer to "resize the viewer".

**Four things that rendered perfectly and were wrong**, all caught in a harness built from the real
source (the [[clinic-smoke-instances]] trick), then confirmed in the app:
1. `NSScrollView.minMagnification` **defaults to 0.25**, so a fit computed at 32% was silently
   clamped to a 50%-on-Retina magnification: the image came up cropped on both axes while the readout
   said 32%. Set the limits, and *read the magnification back* instead of trusting the write.
2. `NSImage.draw` in a flipped view draws upside down — every screenshot arrived inverted.
3. **`clipsToBounds` is false by default** on a current SDK. The checkerboard painted over the matte,
   then the matte painted over the pane's headers and list — the whole panel went dark.
4. **A SwiftUI overlay over an `NSViewRepresentable` is not clickable**: the representable is a real
   `NSView` subview and AppKit's `hitTest` gives it the mouse, so the floating zoom capsule drew and
   did nothing (four clicks, no change, while a sibling list row clicked fine). It became a footer
   band — which also gives an image window the controls for free.
- **And the image moved into a `CALayer`'s contents.** Drawing it meant a 3600 × 2338 pt document
  view inside SwiftUI's layer-backed host — ~134 MB of backing store — and magnification scaled that
  rasterisation, so `imageInterpolation` could never make a zoomed screenshot crisp. Matte,
  checkerboard and outline are painted by the *scroll view* in unmagnified coordinates, so the
  squares stay a constant size on screen at any zoom.

**Verified** with a 4 × 4 hand-written PNG (hard edges prove nearest-neighbour), a 24 px icon with
transparency, a 96 px icon and a 3600 × 2338 Retina screenshot: fit, 126%, 1131%, drag-pan, the
preset menu, the pop-out window, the panel at its 400 pt and 280 pt floors, and the footer's
`ViewThatFits` dropping the file size at ~210 pt of detail column. `swift test --package-path
Packages/ClinicCore` — 265 pass. The smoke run wrote `ClinicImagesShowList` into the real defaults
domain; deleted, and `~/Library/Caches/clinic-smoke` removed.

## 2026-09-10 (cont.) — Finder's keyboard over the Images pane (ADR-107)
User: *"Can we add some keyboard shortcuts that make this more powerful, like tapping 'space bar' when
focused on an image opens a Preview style window (like finder). Enter maybe opens it into a separate
window. Cmd + C to quickly copy the image, etc"*

[[ADR-107 The Images Pane Has A Finder Keyboard]]: space → `QLPreviewPanel` (the system's own panel,
so ‹ › between images, the index sheet, Open with Preview and Escape all come free), return → the
image window, ⌘C → copy, ⌘⌫ → remove, arrows → walk the gallery, ⌘Y → Quick Look from the menu bar.

- **Quick Look is installed from `AppDelegate.beginPreviewPanelControl`** — the panel finds its
  controller by walking the responder chain, and the app delegate is the only link that is in the
  chain whichever half of the pane has focus.
- **`.onKeyPress` never delivers a command chord.** A focusable thumbnail list handled ↑↓/space/return
  and silently dropped ⌘C and ⌘⌫ — measured, by leaving a sentinel string on the clipboard and
  watching it survive. So the viewer's `NSView` is the pane's *one* keyboard (its `copy(_:)` also
  lights up Edit ▸ Copy), and clicking a row hands the keyboard to it. Arrows consequently walk the
  gallery instead of panning, superseding that half of ADR-106.
- **Focus is never taken**, since `show_image` can open the pane mid-sentence; space with the terminal
  focused still types a space (verified). ⌘Y exists precisely because ⌘⇧I → space would otherwise need
  a click in between.

**Three bugs walked into, two older than this work:**
1. `WindowState.updateNSView` re-asserts the agent surface as first responder on every re-render of
   the terminal stack (ADR-081, so focus never lands in a hidden surface) — and adding or removing an
   attachment re-renders it, so ⌘⌫ worked once and the next keystroke went to the session behind the
   panel. `TabContentView.panelHoldsKeyboard` now stops the surface taking the keyboard *out of the
   panel*. The same latent bug applied to the editor and to every browser's filter field.
2. **⌘W with an image (or file) window key closed the session tab**, putting up "Close this session?
   Claude Code is still running" — from a keystroke meant for the picture in front of you.
   `TabStore.closeFront` closes the key auxiliary window first; this is what ADR-081 already claimed.
3. Image windows shared one autosaved frame, so ADR-106's "opens at the image's own size" held for the
   first window and then handed a 96 pt icon a 1579 × 1082 frame. They cascade now.

**Verified** in a smoke instance by synthetic events (guarded on frontmost pid): row click → ↓ moves
the selection and the viewer follows → ⌘C turns a sentinel clipboard into TIFF/PNG (the agent's own
terminal footer then read "Image in clipboard") → ⌘⌫ takes the list 4 → 3 and keeps the keyboard →
space opens Quick Look with Finder's chrome → space closes it → return opens a 380 × 312 window for a
4 × 4 image → ⌘W closes just that window → space with the terminal focused opens nothing → ⌘Y opens
Quick Look with no click at all. Clipboard saved and restored around the run; smoke support dir removed;
no new defaults keys written.

## 2026-09-10 (cont.) — A design pass over the settings window (ADR-108)
User: *"The settings panel is a little unwieldy to use since it can't be re-sized. Its UI/UX leaves a
lot to be desired as well. Help me do a design / ux pass on this to improve it"*

Measured the complaint before changing anything (smoke instance, all five panes screenshotted):
`.frame(width: 560, height: 420)` on the `TabView` gave Shortcuts' ~2100 pt of content a 420 pt
viewport — **six rows of thirty-eight** — while Notifications and Diagnostics wasted half the window,
and nothing could be dragged to fix either. "General" was fourteen controls in date-added order with
no sections.

[[ADR-108 The Settings Window Is A Source List]]: a resizable source-list window; five one-word panes
(General / Sessions / Notifications / Shortcuts / Advanced) with the MCP tool switches folded into
Sessions; every caption a `Section` footer; the shortcut editor gains a filter, a pinned footer bar
and single-height rows.

**Three things worth remembering:**
1. **`LabeledContent` aligns on the first text baseline, and an `NSViewRepresentable` has none** — so
   SwiftUI used the shortcut recorder's *bottom edge* as its baseline, dropped it below the label and
   doubled every row. `.fixedSize()` and `intrinsicContentSize` do nothing about it; the fix is the
   representable's `sizeThatFits` plus an explicit `.alignmentGuide(.firstTextBaseline)`. 56 pt → 28 pt.
2. **A `Settings` scene's window cannot be zoomed or miniaturised**, whatever the style mask says.
   It reported `resizable=true`, `maxSize` unbounded — and the green button was dead. Switched to a
   `Window` scene + `.windowResizability(.contentMinSize)` + `CommandGroup(replacing: .appSettings)`
   to keep ⌘, and the app-menu item.
3. **Synthetic corner-drags do not drive NSWindow's live resize** — four rounds went into a resize
   drag that reported "dragged" and changed nothing, while a titlebar drag with the same tool moved
   the window fine. What settled it was clicking the *zoom button* (780 × 560 → 1800 × 1130). Prefer a
   button click to a drag when proving a window can resize; and prefer an in-app probe to a synthetic
   click for anything in the menu bar (the click guard rightly refuses it — `NSApp.mainMenu` answered
   `Settings…[⌘,]` directly).

**Verified**: five panes at the default size, the pane set and every section; zoom to 1800 × 1130 with
24 shortcut rows visible; the frame surviving quit → relaunch; `-ClinicPreferencesTab tools` and
`diagnostics` still resolving. `swift test --package-path Packages/ClinicCore` — 265 pass. The smoke
runs wrote `NSWindow Frame ClinicSettings`, both `NSSplitView Subview Frames …SidebarNavigationSplitView`
keys and overwrote `NSWindow Frame com_apple_SwiftUI_Settings_window` into the real defaults domain;
diffed against a snapshot taken before the work and restored key for key, and the smoke support dir
removed.

## 2026-09-10 (cont.) — Styling the settings window after System Settings (ADR-108)
User: *"This is a great start, can we update the styling to more closely match the built-in System
Settings"*

Screenshotted the real System Settings (it was already running — read-only, left alone) and matched
it rather than working from memory. Four changes, folded into [[ADR-108 The Settings Window Is A
Source List]] since nothing had shipped yet:

- **Coloured icon tiles** in the source list — white `.fill` glyph on a 20 pt rounded square with a
  `.gradient` fill. The single strongest cue; General/Notifications/Shortcuts take the colours System
  Settings gives its own General, Notifications and Keyboard.
- **An empty title bar** (`titlebarAppearsTransparent`, `titleVisibility = .hidden`, no
  `navigationTitle`) so the source list runs to the top with the traffic lights over it, and the pane
  name moves into the content as a 17 pt bold title. Shortcuts puts its filter in the same band.
- Source list 186 → **215 pt** (System Settings' is 222).
- **A 760 pt column** holding the title bar and the form together.

**Two things worth remembering:**
1. **A grouped `Form` caps and centres its own boxes past ~760 pt.** That is why a fixed-inset title
   bar above one drifts out of alignment on a wide window — the boxes move and the title does not.
   Pinning both to one column is the fix, and it holds in a zoomed window too.
2. **A `Section` footer's ideal width propagates to the scene.** One long unwrapped line of footer
   text made the `Window` scene open **1027 × 795** on a first run, ignoring `idealWidth`; the
   deferred `setContentSize` had already run by then, so it did not correct it. Bounding the column
   bounds the ideal and the window opens at 780 × 560. Suspect an unwrapped `Text` whenever a SwiftUI
   window opens wider than it was asked to.

**Verified**: all five panes at 780 × 560 against the System Settings screenshot; the title on the
boxes' left edge at 780 pt and zoomed to 1800 pt; the green button still resizing 780 × 560 →
1800 × 1130. `swift test --package-path Packages/ClinicCore` — 265 pass. Smoke defaults diffed and
restored, smoke support dir removed.

## 2026-09-10 (cont.) — Clinic's own sidebar and its own glyphs (ADR-108)
User: *"I was thinking visually that the sidebar might look more like the sidebar in the main part of
the app where it flows up and behind the window controls. Also, I'm not sure I like the visual of
those main setting icons (though they are like the system settings). Maybe we can stick more with the
glyphs we use elsewhere and put them in a container/shape that takes on the accent color."*

Both right, and the second one caught a real drift: the `.fill` symbols the System Settings tiles
wanted were **the only filled symbols in the app**. The tiles now carry Clinic's own outline glyphs
(`gear`, `terminal`, `bell`, `keyboard`, `wrench.and.screwdriver`) on an accent tint at 0.16 — the
on-state `PaneIconButton` already draws. One colour for all five; the glyph carries the meaning.
Built the solid-accent variant too and sent both side by side; solid competes with every
accent-coloured control in the pane beside it, so the tint ships.

**`.toolbar(removing: .sidebarToggle)` is what made the sidebar an inset floating panel.** A
`NavigationSplitView` only unifies its sidebar with the title bar when the window has a toolbar, and
removing the only toolbar item leaves it with none — so the sidebar became macOS 26's inset rounded
panel starting *below* the title bar, instead of the main window's flat full-height column with the
traffic lights on it. Four wrong guesses first, each plausible because the main window does them:
`titlebarAppearsTransparent`, `.windowStyle(.titleBar)`, `.navigationTitle`, and wrapping the `List`
in a `VStack` (the main window's `SidebarView` is a `VStack` around a `List`). All four removed again
after testing them one at a time — the toggle was the whole cause.

The toggle was removed in the first place on the theory that hiding the list would strand a reader
with no way back. Tested it: **the toggle follows the collapse**, sitting beside the traffic lights,
so it never could.

**Also worth remembering:** `screencapture -x -o -l` gives *exact* window pixels with no shadow
padding (checked three captures against their point sizes), so measuring alignment straight off a
screenshot is sound — the shadow-padding caveat in [[clinic-smoke-instances]] applies to captures
without `-o`.

**Verified**: all five panes at 780 × 560; the sidebar flat and full-height with the lights on it;
collapse and restore via the toggle; the pane title still on the boxes' left edge.
`swift test --package-path Packages/ClinicCore` — 265 pass.

## 2026-09-10 (cont.) — The pane's name belongs in the title bar (ADR-108)
User: *"Bug 1, on first open 'General' or the default tab doesn't display in the window menu bar.
Additionally, we should only display the section or tab name in the same bar and remove from
content"*

Both the bug and the request have one cause and one fix. The System-Settings pass had set
`window.titleVisibility = .hidden` so the window title would not collide with the pane name drawn at
the top of the content — so the title bar showed nothing, ever. Once the sidebar became a *unified*
one (the previous entry), the content's title also sat one line below the bar that should have been
carrying it, saying the same word twice.

`titleVisibility` is left alone now, `.navigationTitle(pane.title)` names the window, and no pane
draws a title of its own. `SettingsPaneTitleBar` and `SettingsPaneBody` are deleted; panes are just
their `Form` held to the column. Shortcuts' filter moved into the **toolbar** beside the pane name —
it was the only pane that needed chrome there, and a band holding one field would have been exactly
the second bar this change removes. Nine shortcut rows fit where eight did.

**Verified**: launched with no `-ClinicPreferencesTab` at all (the real default path) — title bar
reads "General" on first open, and follows the selection through clicks on Sessions and Shortcuts,
read back from `kCGWindowName`. All panes at 780 × 560 with no duplicated title.

## 2026-09-10 (cont.) — Don't paint over Liquid Glass (ADR-108)
User: *"Looks like the search bar in Shortcuts is overlapping an other one, we should use the modern
liquid glass version here"*

Exactly right, and the zoomed screenshot showed two offset capsules in the corner of the window.
**macOS 26 wraps a custom `ToolbarItem` in a Liquid Glass container of its own**, so `TreeFilterField`
— which paints its own capsule fill and border (ADR-103) — landed inside a second one. Reaching for
the house component was the wrong instinct here: the system search field *is* the glass one, and the
way to get that material right is to not draw over it. `.searchable(text:placement:.toolbar,
prompt:)` and the doubling is gone.

The one thing `TreeFilterField` carried that the system field has nowhere to put is the match count,
so it moved to the footer bar beside *Reset All* — "how much of this list am I looking at" is the one
question a filtered list cannot answer on its own.

**Also corrected a number I had been repeating:** there are **37** rebindable actions, not 38. Counted
the `ShortcutAction` cases from source rather than by eye; ADR-108 said 38 in three places and now
says 37. The live footer reading "6 of 37" is what caught it — a good argument for putting a computed
count on screen where you have to look at it.

**Verified** by synthetic click into the field and typing "new": six rows survive across File and
Session, the footer reads "6 of 37", and the field is a single capsule with the focus ring.

## 2026-09-10 (cont.) — The sidebar toolbar, sized like the nav rows (ADR-109)
User: *"Lets increase the size of the actions above the projects in the sidebar. Let's do a UI/UX
improvement pass"*

The row (Select, Collapse All, Expand All, Add Project) was ADR-077's "compact" 11 pt glyphs in
22 × 20 boxes, the smallest thing in the sidebar. It now takes the nav rows' measurements: **14 pt
glyph, 28 × 24 box, 6 pt corner, 10 pt inset**. The last of those lines Add Project up with the nav
pills and the search field.

**13 pt was the first build and it wasn't enough.** It matches the nav glyphs' *point size*, but those
are filled symbols and these are outlines, so they still looked a step lighter in the real app. Size to
visual weight, not to the number on the neighbouring view.

The pass also fixed what the screenshot showed besides size:
- **Expand All was `chevron.down`, the same glyph as every project header's disclosure chevron** a few
  points below it. Collapse All was `chevron.up.chevron.down`, the pop-up/stepper mark. They are now
  converging and diverging arrows on a line. `rectangle.compress/expand.vertical` rendered busy at
  this size.
- Select mode now shows as **latched** (accent glyph on an accent wash), not just an accent glyph.
- **The fold buttons disable when they'd do nothing**: everything already collapsed or expanded, or
  a filter typed, since folding is suspended while filtering.
- Each button uses its help text as its accessibility label, not the symbol name.

A "Projects" caption on the empty left side was reconsidered and dropped. It fails for the same reason
ADR-077 removed "Sessions": with favourites, the first section under it is Favorites.

**Verified** in a smoke instance (three seeded projects, one collapsed, empty `CLAUDE_CONFIG_DIR`):
14 pt reads at the nav glyphs' weight. Clicking Select latches it. Hovering Collapse All fills it.
Clicking Collapse All folds all four groups (read back from the smoke `state.json`), after which
Collapse All dims and Expand All stays live. The real `com.r0adkll.clinic` defaults domain was
exported before the run and matched it exactly after.

## 2026-09-10 (cont.) — A "Projects" trial, a hover that never existed, and nav tiles (ADR-110, ADR-111)
Three asks in a row: *"Let's add the "Projects" title just to see"*, *"the hover state on sessions is
not visible in dark mode (or light mode even?)"*, *"Then lets beef up the top nav items in the
sidebar"*.

**"Projects" caption: trial, not yet decided.** The toolbar now has a `.subheadline` semibold
secondary "Projects" caption, starting where the nav glyphs start. With a favourite seeded, the smoke
screenshot shows the problem ADR-109 predicted: "Favorites", in almost the same style, sits directly
under it and reads as a sub-section of Projects. Shown to the user; ADR-109's "no caption" bullet
changes only if they keep it.

**The session hover wasn't faint, it was absent.** A `.sidebar` `List` draws no hover state, and
`SessionRow.hovering` only swapped the badges for the actions. ADR-077's phrase "selection and hover
fills" had described a hover fill no one built. Fixed with a `listRowBackground` pill in `.quaternary`
(ADR-110). **Measure the system's shape, don't guess it:** a small pixel-profile tool (the first
x that differs, per scanline, across a corner) showed the selection corner at about 8 pt against the
first guess of 6. After the change both profiles agree within a pixel.

**Nav rows** now lead with the project header's 22 pt colour tile (orange / blue / purple), a 14 pt
label and a 30 pt pill with an 8 pt corner (ADR-111). Four variants were rendered in a harness; grey
tiles read as disabled next to the coloured project tiles, and a bigger bare glyph was still the
plainest row in the sidebar.

**Verified** in smoke instances, dark and then light (`-NSRequiresAquaSystemAppearance YES`), seeded
with two transcripts and a favourite. Select mode was used to get a selected row without clicking one
open, because a plain click would have run `claude --resume` on a fake session. The real defaults
domain matched its export afterwards.

## 2026-09-10 (cont.) — Nav tiles take the accent, like Settings (ADR-111 revised)
User: *"Let's try the D option for the nav rows, but make it the accent color like we did in settings"*

The per-destination colour tiles are gone. The nav rows now draw the Settings source list's tile
(`SettingsPaneIcon`, ADR-108) at the sidebar's 22 pt tile size: an accent outline glyph on a 16 %
accent wash with a 5 pt continuous corner. On the active row, whose pill is the accent, the tile turns
white on white at 22 % so it doesn't vanish. The glyphs switched to their outline forms (`storefront`,
`alarm`); that also makes the block uniform for the first time, since `server.rack.fill` doesn't exist
(ADR-095). ADR-111 was rewritten in place (renamed to *Nav Rows Wear Accent Tiles*): it was drafted
this session and never committed, and the colour-tile version is kept in its Options as the path
not taken.

This is the second time the user has turned down a per-item palette in favour of one accent (ADR-108
was the first). Default to accent-tinted tiles for any new icon container.

**Verified** in dark and light smoke instances with MCP Servers active and Marketplace hovered.
Defaults domain unchanged.

## 2026-09-10 (cont.) — "Projects" stays, and the list gets some air (ADR-109)
User: *"Add a bit more padding between the nav items and the projects bar/list. I also like the
"Projects" title so we can keep that"*

The caption trial is now a decision: ADR-109 records "Projects" as kept, reversing ADR-077's "no
caption", and notes the Favorites-under-Projects cost the user saw and accepted. The toolbar row now
has 12 pt above it instead of 4, so the Automations → Projects step goes from 30 to 38 pt
centre-to-centre, measured on smoke screenshots before and after. With the gap, the row reads as the
header of the list, not a fourth nav row. Defaults domain unchanged.

## 2026-09-10 (cont.) — Tasks: issues from every project, and sessions from issues (ADR-112..114)
User: *"Let's design and develop a "Tasks" feature, a full screen issues/task list manager through the
side bar navigation … Grill me to help build the full design"*

Four grilling rounds settled the design (35 questions). Tasks is a viewer and a launchpad, not a
tracker. It shows **issues only**, aggregated across every project, with UI word "Tasks" and model word
`WorkItem` (ADR-025 amended). A **source** (provider + host + scope) is separate from a project, and
GitHub sources come from `gh repo view` run in the project folder. The screen has three panes
(scope column | list | detail), filters are menus plus plain search, and label washes use GitHub's
own colours (the user chose them over neutral capsules). Start Session opens the composer pre-filled
with a worktree, and ⌘↩ starts one straight away. Clinic remembers each issue ↔ session link.

Where the build deviated from the grilling, and why (recorded in the ADRs):
- **Glyph `list.bullet.clipboard`, not `checklist`**: the sidebar toolbar's select-mode toggle already
  uses `checklist`, one row below.
- **Views switch with ⌃1–⌃4**: ⌘1–⌘9 are the Tabs menu's "Tab 1…9". My first grep missed them because
  they're built in a loop. This was the fallback the grilling had agreed.
- **Flat project list**: ADR-062's "project groups" are the per-project sections, so there is nothing to
  nest under.
- **List transport is paginated GraphQL, not `gh issue list`**: that command can only report a comment
  count by shipping up to 100 full comment bodies per issue (measured 73 KB for 20 issues on `cli/cli`).

Built in three commits on `feature/tasks`: the ClinicCore model and GitHub provider with fixture tests
(291 tests green), `TasksStore`, then the screen, the detail pane and the session links.

Two traps found in the smoke run:
- **The first refresh resolved nothing.** `-ClinicScreenOnLaunch tasks` shows the screen before the
  session scan has built the project list. `TasksStore.refresh` now waits for `initialScan`, and new
  projects resolve as soon as they appear.
- **The thread web view stayed blank.** The Swift 6 "nearly matches optional requirement" warning on
  `webView(_:decidePolicyFor:decisionHandler:)` means WebKit never calls the policy method. With the
  correct `@MainActor @Sendable` handler it *is* called, and ADR-090's `webView.url == nil` test then
  cancels the `loadHTMLString` load itself (the URL is already the base URL by then). Tasks allows the
  base URL explicitly. **`GitHubHTMLView` still has the mismatched signature**, so the PR panel's
  open-links-in-the-browser policy has never run. It's left as it was and reported to the user.

**Verified** in a `CLINIC_APP_SUPPORT` smoke instance against live `gh`, with four projects:
- three resolved (clinic, upload-google-play, ditto), and the non-git folder dimmed as "Not a git
  repository";
- 10 open issues, 2 assigned to the user, 1 mention;
- label washes, the thread with avatars and code blocks, and the composer pre-filled with
  `issue-265-dep0040-dep0169-deprecation-warnings`.

New smoke keys: `-ClinicScreenOnLaunch tasks`, `-ClinicTasksView`, `-ClinicTasksSelectAfterLaunch` and
`-ClinicTasksComposeOnLaunch`. The run wrote `ClinicTasksFilters` into the real defaults domain, and it
was deleted afterwards.
