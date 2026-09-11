---
status: accepted
date: 2026-09-11
amends: ADR-079 (a run pane kind), ADR-056 (run tools), ADR-050 (`.clinic/run.json`, a Run submenu), ADR-019 (run surfaces may move between hosts)
tags: [adr, ui, projects, terminal, mcp]
---
# ADR-122: Projects have run configurations

## Context
User (2026-09-11): *"It would be nice to have an action to "run" a project. For example, in my
Campfire project its a Kotlin multiplatform setup on Gradle that can run the android app, the
desktop app (or hot reload desktop app), or execute its iOS app. For clinic, its a macOS xcode app,
etc. Can we explore a design/feature that would allow us to run (or setup run configurations) for
projects?"*

Nothing in Clinic runs a project today. The closest pieces are the panel shell ([[ADR-079 Panel
Tabs]]) and `run_in_terminal` ([[ADR-056 Session MCP Tools]]), which types a line into that shell
and never learns how it ended.

**What "run" means across the user's repos** (surveyed 2026-09-11, `~/SoftwareProjects/main` plus
Campfire):
- **Most repos have several targets, reached by a shell command.** Campfire has
  `./gradlew :app:desktop:run` and `:app:android:installAlphaDebug`/`installBetaDebug` (two
  flavors, so plain `installDebug` does not exist). Ditto has `:catalog:desktop:run`,
  `:catalog:android:installDebug` and `:catalog:web:wasmJsBrowserDevelopmentRun`. The other repos
  follow the same pattern: livewire-presentation runs `hotRunJvm`, the IntelliJ plugins `runIde`,
  the Cargo repos `cargo run -p …`, and collins `./start-debug`.
- **Some runs are two processes at once.** Livewire has JetBrains compound configurations
  (*Android + Host*, *Desktop + Host*). Shopkeep's VS Code `dev` task runs `dev: server` and
  `dev: web` in parallel.
- **The only run-configuration files checked in are JetBrains XML** (`livewire/.run/` ×6,
  `SwatchBuckler/intellij-plugin/.run/` ×1, `Campfire/.idea/runConfigurations/` ×3) **and one VS
  Code `tasks.json`** (shopkeep). No repo has `launch.json`, Zed or Fleet tasks, a Procfile or a
  justfile.
  - The Gradle, shell-script and compound JetBrains types map to a shell command.
  - The Android, Application and KMM iOS types do not: they name a module, a main class or an
    Xcode scheme and leave the rest to the IDE.
- **Apple targets need project, scheme, configuration and (for iOS) a destination.** Campfire's
  iOS configuration stores exactly the first three for `app/ios/iosApp.xcodeproj`. Clinic's own
  Makefile builds but has no `run` target.
- **Guessing Gradle targets from build files is fragile.** Flavors, KMP source sets and plugin
  aliases in version catalogs all hide the task name. Asking Gradle (`./gradlew tasks --all`) is
  slow. Claude reading the build is more reliable than either.

**What the code already offers:**
- **Exit status.** The bridge reports `show_child_exited` with an exit code
  (`GhosttySurfaceView.swift:460`). When a surface's `command` is set, libghostty waits after it
  exits, so the output stays on screen. **The code itself is useless on macOS**, found while building
  this on 2026-09-11: libghostty starts every surface command as `/usr/bin/login -flp <user>
  /bin/bash -c "exec -l <command>"`, and `login` exits 0 whatever its child did
  (`/usr/bin/login -qflp $USER /bin/bash -c 'exit 3'` returns 0). A failing build first showed
  *Succeeded*. OSC 133 `command_finished` also reaches Clinic, but it needs shell integration
  that Clinic does not bundle ([[ADR-034 Ghostty Config Overrides and Shell Integration]]).
- **The rc-file environment.** `$SHELL -l -i -c '<cmd>; exit 3'` returned 3 under both zsh and fish
  on this machine. A login-interactive shell also loads rc files, where `JAVA_HOME` and
  `ANDROID_HOME` usually live. ADR-086's login-only probe skips them.
- **Reading output.** `visibleText` reads only the viewport. `GHOSTTY_POINT_SCREEN` covers the
  scrollback, so a bridge helper can read a run's whole output.
- **A split toolbar button**: [[ADR-078 Open In Targets and Quick Action]]'s is the pattern to copy.

## Options
Four questions were put to the user on 2026-09-11. The chosen answer is in bold.

| Question | Options |
|---|---|
| Where does a run's output live? | **A pane in the right panel**; a tab in the tab bar; a project-wide drawer under the terminal |
| Where are configurations stored? | **`.clinic/run.json` in the repo**; Clinic's `state.json`; both, shared plus private |
| How are they created? | **All four:** set up with Claude, an editor sheet, importing IDE configs, built-in detection |
| What can a session do with runs? | **All three:** *Fix with Claude* on failure, MCP run tools, re-run when a turn ends |

## Decision

### A configuration is a named shell command
`<project>/.clinic/run.json`, beside the icon ([[ADR-050 Project Decoration and Actions]]):

```json
{
  "version": 1,
  "default": "desktop",
  "configurations": [
    { "id": "desktop", "name": "Desktop", "icon": "desktopcomputer",
      "command": "./gradlew :app:desktop:run" },
    { "id": "android-alpha", "name": "Android (alpha)", "icon": "iphone",
      "command": "./gradlew :app:android:installAlphaDebug",
      "env": { "ANDROID_SERIAL": "emulator-5554" }, "rerunAfterTurn": true },
    { "id": "dev", "name": "Server + Web", "compound": ["server", "web"] }
  ]
}
```

- **Fields**:
  - `id` is unique within the file.
  - `name` is required.
  - `icon` is an SF Symbol name, drawn as an accent tile ([[ADR-111 Nav Rows Wear Accent Tiles]]).
    It defaults to `play.fill`.
  - `command` is one shell command line.
  - `directory` is relative to the checkout and defaults to `.`.
  - `env` and `rerunAfterTurn` are optional.
- **Compounds**: a configuration with `compound` (member ids) and no `command` starts each member
  at once.
- **`default`** is only the first selection. After that, the selection lives per project in
  `state.json` (`runSelectionByProject`) and never in the repo.
- **Clinic writes the file only from the editor sheet**, pretty-printed. Keys it does not know are
  kept. Clinic never commits it, and whether it is committed is the user's choice.
- **The checkout's own file wins.** A worktree on a branch that changed `run.json` uses its own
  copy. Otherwise the file is read from the project root, so an untracked `run.json` still reaches
  worktrees. Every file Clinic has read is re-read when its modification date moves: a stat every 2 s while Clinic is active. That catches Claude writing the file and a `.clinic/` folder appearing, which a watcher on the folder could not.
- **A file that does not parse** shows its error in the Run menu and the editor. Clinic never
  overwrites it.

### A run is the surface's own child process
- **Where it runs.** A run is keyed by (checkout, configuration id). The checkout is the directory
  the tab is working in: the project root, or its `.claude/worktrees/<name>`. Running from a
  worktree session runs the worktree's code, which matches the Open In quick action (ADR-078).
- **How it launches.** The surface's `command` is a `/bin/sh` wrapper around the user's
  `$SHELL -l -i -c '<command>'`, everything quoted with `ClaudeLaunch.shellQuote`, with `env`
  added to Clinic's `CLINIC=1`.
  - Nothing is typed into a prompt, so the process's exit is the run's end.
  - The run gets colour, interactivity and the rc-file environment.
  - **The wrapper records the exit code** in `Clinic/runs/<uuid>.status` under Application Support
    before it exits, and Clinic reads and deletes that file when the child exits. That is the only
    trustworthy code on macOS (see Context). No file means the wrapper was killed before writing:
    the code is unknown.
  - The wrapper traps SIGINT with a no-op handler, not an ignore. An ignored signal is inherited by
    the command, which could then never be interrupted. A handler resets across `exec`, so Ctrl-C
    still stops the command, and the wrapper survives to record 130.
  - This is a new shape beside [[ADR-016 Launch Shape]], which still governs sessions and shell
    tabs.
- **States:**

  | State | What's shown |
  |---|---|
  | Running | Elapsed time |
  | Succeeded | Exit 0, with the duration |
  | Failed | The exit code |
  | Stopped | Stopped by the user |

  A build-style run ends green or red. A long-running one (desktop app, dev server, `hotRunJvm`)
  stays *Running* until it exits or is stopped. Clinic does not need to know which kind a
  configuration is.
- **Stop** sends Ctrl-C. If the process is still alive after 5 s, Clinic sends SIGTERM to the
  pty's foreground process group, then SIGKILL 3 s later. The surface stays, so the output does too.
  A Gradle daemon outliving its client is expected.
- **Restart** stops the run, waits for the exit, then starts a fresh surface in the same pane.
  Running a configuration that is already running in that checkout restarts it.
- **Notifications.** A run that ends while its pane is not on screen posts a notification
  ([[ADR-033 Notification Delivery]]): *Android (alpha) succeeded in 48 s* or *Desktop failed
  (exit 1)*.
- **Runs die with the app** and are not restored at launch, like panes (ADR-079). *Keep Running*
  ([[ADR-069 Keep Running and Quit Behaviour]]) keeps them alive, and the quit sheet lists running
  runs beside working sessions.

### Output is a pane in the right panel
- **`PanelPane.Kind.run(RunKey)`**, keyed per run the way PR panes are keyed per ref. The chip
  shows its name and a state mark in place of the configuration's icon. The marks are
  [[ADR-096 Session Status Indicators]]'s vocabulary: motion carries running, colour marks only
  outcomes, and nothing is ever the accent colour.

  | State | Mark |
  |---|---|
  | Not started | The configuration's icon, `.secondary` |
  | Running | The spinning arc, in the label colour |
  | Succeeded | ✓ `.green` |
  | Failed | ✗ `.red` |
  | Stopped | Hollow ring, `.secondary` |

  The same marks appear in the toolbar button, the pane header and the Run menu. ADR-078 found that
  macOS draws toolbar images grey, so ✓ and ✗ must read by shape there, not by colour.

- **The run belongs to the checkout, not the tab.** `RunStore` (main actor, app target) owns every
  run and its surface. Closing a session tab does not stop a run.
  - Any session or shell tab in the same checkout can show the run's pane. It is offered in the
    panel's `+` menu, and the Run button fronts it.
  - The surface is hosted by whichever panel fronts it. This is an exception to [[ADR-019 Window
    and Surface Lifetime]], which still holds for agent surfaces: run surfaces are re-parented.
  - If a second window fronts the same run, that window takes it. The first window shows
    *Showing in another window* with *Show Here*.
- **Running from the UI opens and fronts the pane** (ADR-079's opener rule). A re-run after a turn
  never fronts anything; only the chip and the toolbar change.
- **The pane's header** is the shared 34 pt band ([[ADR-102 One Chrome For Every File Browser]]).
  It shows the configuration's icon and name, the checkout's branch, then the state mark with the
  elapsed time, *Succeeded in 48 s*, *Exit 1* or *Stopped*, then *Restart* and *Stop*. A failure
  adds a bar under the output: *Failed with exit code 1 · 38 s*, then *Restart* and a prominent
  *Fix with Claude* (below). *Open in Editor* opens the failing file when the output
  names one: deferred.

### Controls
- **Toolbar split button**, left of Open In and built the same way:
  - **Button**: the selected configuration's icon (`▶` until it has one — amended by [[ADR-125 The
    Icon Picker Browses Every Symbol]]), or the run's state mark, + its name, plus the
    elapsed time while it runs. It runs, or restarts when the run is already going. **The name is
    shown**: a 196 pt pill, so ⌘R's target is visible without opening anything. The user chose
    this on 2026-09-11 over a glyph-only capsule like Open In's, from the design canvas that drew
    both.
  - **`■` Stop**: beside the button while the *selected* configuration is running in this checkout.
    Other runs are stopped from their panes or the menu.
  - **Menu**:
    - the project's configurations, the selected one checked, each with its last state mark and
      time on the right;
    - a *Detected* section (below);
    - *Edit Configurations…*;
    - *Set Up with Claude…*;
    - *Import from IntelliJ / VS Code…*, shown only when those files exist.
  - **With no configurations** it reads *▶ Run…* and its click opens the editor — amended by
    [[ADR-126 An Unconfigured Run Pill Opens The Editor]].
  - **Hidden** for Chats (no project) and Replay tabs.
- **A Run menu** in the menu bar:

  | Item | Chord |
  |---|---|
  | Run | ⌘R |
  | Stop | ⌃⌘. |
  | Choose Configuration… (a picker: ↩ chooses, ⌘↩ chooses and runs) | ⌃⌘R |

  Below those come the configurations as checkable items, then *Edit Configurations…* and *Set Up
  with Claude…*. ⌘. stays *Stop Session*. The chords are new `ShortcutAction` cases in a **Run**
  section of the shortcut editor ([[ADR-073 Rebindable Shortcuts]]).
- **The project menu** (ADR-050) gains a *Run ▸* submenu listing the configurations. These run in
  the project root. The pane opens in the selected tab when it is in the root checkout, else in
  another tab there, else in a new shell tab in the root, so the output always has somewhere to go.
  A project with nothing configured offers *Set Up Run Configurations with Claude…* instead.
- **⌘R with nothing configured** opens the ⌃⌘R picker, which lists what detection found and
  offers the set-up paths.

### Four ways to get configurations
1. **Set Up with Claude…**
   - Opens the composer ([[ADR-082 New Session Screen Composer]]) in the project root, worktree
     off, with an editable prompt that carries the schema.
   - The prompt tells Claude to:
     - read the build: Gradle modules and flavors, Xcode projects and schemes, `package.json`,
       Makefiles, scripts, READMEs and IDE run configs;
     - write `.clinic/run.json`;
     - check that each task or target exists without starting long builds;
     - leave committing to the user.
   - The user reviews the result in the Diff panel ([[ADR-080 Diff Panel]]).
   - This is the answer for KMP and Apple targets that detection cannot see. That includes an
     iOS simulator run as an `xcodebuild … && xcrun simctl install … && xcrun simctl launch …`
     command.
2. **The editor sheet** (*Edit Configurations…*):
   - List-plus-detail like the automation editor ([[ADR-095 Automations]]): accent-tile rows on the
     left, `+`/`−` below them.
   - The detail side holds name, an icon picker (a curated SF Symbol set), the command (a
     monospaced multi-line field), directory, an env table and *Re-run after each turn that
     changes files*. A compound instead shows a checklist of the other configurations.
   - *Save* writes `run.json`.
3. **Import.** A preview sheet with a checkbox per found configuration. The copy is one-time, not a
   live link. It reads:
   - **JetBrains** `.run/*.run.xml` and `.idea/runConfigurations/*.xml`:
     - `GradleRunConfiguration`: `taskNames` + `scriptParameters` under `externalProjectPath`
       become `./gradlew …`, or `gradle …` when there is no wrapper.
     - `ShConfigurationType`: `SCRIPT_TEXT`, or `SCRIPT_PATH` + `SCRIPT_OPTIONS`, in its working
       directory.
     - `CompoundRunConfigurationType`: becomes a compound.
     - `$PROJECT_DIR$` becomes `.`.
   - **VS Code** `tasks.json` (JSON with comments): `shell` and `process` tasks, from `command` +
     `args` + `options.cwd`/`env`. `${workspaceFolder}` becomes `.`. `dependsOn` with
     `dependsOrder: parallel` becomes a compound.
   - Anything else is listed greyed with the reason. That covers Android, Application and KMM
     types, other macros, and sequential `dependsOn`. *Set Up with Claude…* can translate those.
4. **Built-in detection.**
   - **Pure parsers** in ClinicCore read files only and never run a build tool. Results are cached
     by file mtime. They run when the Run menu first opens for a checkout, and again when a build
     file changes.
   - **What they detect:**

     | Source | Detected as |
     |---|---|
     | Makefile | Explicit targets, as `make <target>` |
     | `package.json` scripts | Through the package manager its lockfile names |
     | Cargo | Binaries and workspace members, as `cargo run -p …` |
     | `Package.swift` | Executable targets, as `swift run …` |
     | Gradle | Modules from `settings.gradle(.kts)`, each by plugin (see below) |

     Gradle modules by plugin:

     | Plugin | Task |
     |---|---|
     | `com.android.application` | `install<Flavor>Debug` for each flavor found, else `installDebug` |
     | `compose.desktop.application` | `run` |
     | `org.jetbrains.compose.hot-reload` | `hotRunJvm` |
     | `application` | `run` |
     | the IntelliJ Platform plugin | `runIde` |
     | a `wasmJs` target | `wasmJsBrowserDevelopmentRun` |

   - **Xcode macOS app schemes** come from `xcodebuild -list -json`, a bounded subprocess. They run
     as a build into `build/` followed by `open` of the product. iOS targets are left to Claude
     until a destination picker has its own ADR.
   - **Detected entries are runnable at once** from the *Detected* section. *Save to Configurations*
     copies one into `run.json`.

### What sessions can do
- **Fix with Claude.**
  - **When it appears**: in a session tab whose checkout ran a configuration that failed.
  - **What it sends**: the command, the exit code and the last 200 lines of the run's scrollback,
    pasted into the session as a prompt ending *"Find the cause and fix it."*
  - **When it is off**: while the session is working ([[ADR-026 Session State Machine]]).
- **MCP tools** (ADR-056), for the session's checkout:

  | Tool | What it does |
  |---|---|
  | `list_run_configurations()` | Lists the configurations with their state |
  | `run(name)` | Starts or restarts one and returns at once, because the relay times out after 15 s. Its pane opens in the session's tab without being fronted |
  | `read_run_output(name, lines)` | Returns the state, exit code, duration and the scrollback's tail |
  | `stop_run(name)` | Stops it |

  Each tool has a switch under Settings → Session tools. `list_run_configurations` and
  `read_run_output` are on by default. `run` and `stop_run` are on by default behind the trust
  rule below.
- **Trust rule.** Claude can write `run.json`, and a cloned repo can ship one, so "a configuration
  exists" must not mean "an agent may execute it".
  - **Trusted**: Clinic records a hash of each command in `state.json` when the user runs that
    configuration from the UI or saves it in the editor sheet.
  - **Untrusted**: `run` refuses a command whose hash is unknown. Its error tells Claude to ask the
    user to run it once.
  - **Why it matters**: `run` is not a way around Claude Code's own permission prompts for Bash.
  - **Runs from the UI** never ask. The user chose to run it, the same as typing `make`.
- **Re-run after a turn.** When a `Stop` hook ends a turn that changed files, Clinic re-runs every
  configuration with `rerunAfterTurn` that already has a run in that session's checkout, running or
  finished. The turn's snapshot ([[ADR-080 Diff Panel]]) decides whether files changed, or
  `git status` when there is none. Nothing that was never started gets started. This covers
  desktop apps without hot reload and redeploying to a device.

## Consequences
- **ClinicCore (Foundation only)**, in a `Run/` folder:
  - `RunConfiguration` and `RunConfigurationFile` (tolerant decode, round-trips unknown keys);
  - `JetBrainsRunImporter` (Foundation `XMLDocument`) and `VSCodeTasksImporter` (a JSONC comment
    and trailing-comma strip before `JSONSerialization`);
  - `RunDetector`, one pure parser per ecosystem, and `RunTrust`;
  - fixture tests for each ([[ADR-044 Fixture Strategy]]).
- **App target**:
  - `RunStore`, `RunPane`, `RunToolbarButton`, `RunConfigurationsSheet` and `RunImportSheet`;
  - the Run menu and shortcuts;
  - the four MCP tools;
  - the quit sheet's run list.
- **GhosttyBridge** gains `screenText` (the scrollback through `GHOSTTY_POINT_SCREEN`) beside
  `visibleText`. The `surfaceChildExited` docs now warn that on macOS the code is `login`'s.
- **Smoke keys** (ADR-038): `-ClinicRunOnLaunch <id>[,<id>…]`, `-ClinicRunSheetOnLaunch
  edit|import|choose` and `-ClinicStopRunAfterLaunch <seconds>`.
- **Other stores.** `.clinic/` becomes a directory Clinic both reads and writes into
  repositories. `state.json` gains `runSelectionByProject` and `trustedRunCommands`.
- **Deferred:**
  - a typed Xcode configuration kind with a simulator or device destination picker (its own ADR);
  - re-run on file change, as opposed to on turn end;
  - run history;
  - Run entries in ⌘K and the menu bar status item;
  - a running mark on the sidebar project header;
  - output links (file:line → editor);
  - sequential compounds (`dependsOn` in order).
