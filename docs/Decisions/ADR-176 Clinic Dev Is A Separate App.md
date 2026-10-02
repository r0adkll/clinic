---
status: accepted
date: 2026-10-02
amends: "[[ADR-038 Preferences and Diagnostics]] (the smoke instance stays for scripted checks; the dev loop gets an app of its own), [[ADR-167 The Hook Socket Is Not Taken From A Live Instance]] (two instances sharing `state.json` is no longer how Clinic is developed), [[ADR-095 Automations]] (the wake agent wakes the flavor that ships it)"
tags: [adr, build, process]
---
# ADR-176: Clinic Dev is a separate app

## Context
User (2026-10-02), before starting the mods work ([[Log]], 2026-10-02): *"one thing we need to make sure to
solve first is running separate instance of Clinic from clinic so we can safely iterate on new changes while
not messing up our 'production' configuration/environment"*

Clinic is developed from sessions running inside Clinic. The app the user works in is a Debug build with the
bundle id `com.r0adkll.clinic`, and until now a build under test was the same app launched a second time:

- `CLINIC_APP_SUPPORT` moves state, sockets and chats, but `UserDefaults` is keyed by bundle id, so every
  preference a test build writes lands in the real app ([[ADR-038 Preferences and Diagnostics]]).
- Without that variable the two share `state.json` ([[ADR-167 The Hook Socket Is Not Taken From A Live Instance]]).
- Both are a process called `Clinic` with one Dock icon, so telling them apart means reading environments.
- Launched from a Clinic terminal, the test build inherits that Claude Code session's environment.
- The mods work changes how hooks reach the app, which is the part a shared instance can least afford to break.

## Options
- **Keep the smoke instance and add a `UserDefaults` suite.** Rejected in ADR-038 already: it touches every
  `@AppStorage`, and the two would still be one app to macOS.
- **A `Dev` build configuration in the project.** Rejected for now: local Swift packages build as Debug or
  Release, and a third configuration name is a known source of missing-module failures.
- **Re-identify a copy after the build**, as `make screenshots` does ([[ADR-159 How Clinic Presents Itself]]).
  Rejected: the name, the data directory and the helpers would still say Clinic.
- **Three build settings overridden on the command line.** Chosen.

## Decision
- **The flavor is three build settings**, defined in `project.yml` with the released app's values:
  `CLINIC_APP_NAME`, `CLINIC_BUNDLE_ID` and `CLINIC_DATA_DIRECTORY`. The app target's product name, bundle id
  and Info.plist read them. The module is always `Clinic`.
- **`make dev` builds *Clinic Dev***: `com.r0adkll.clinic.dev`, data in `~/Library/Application Support/Clinic Dev`,
  derived data in `build/dev`. It then quits a running Clinic Dev and launches the new one. `make dev-build`,
  `make dev-stop` and `make dev-reset` do the parts; `scripts/dev` is the implementation.
- **The project's run configurations run Clinic Dev.** `.clinic/run.json` defaults to *Clinic Dev*
  (`scripts/dev attached`): build, quit a running one, then run the app as the run's own child, so the pane
  shows its output and stopping the run quits it. *Build Clinic Dev* and *Reset Clinic Dev* sit beside it.
  The old *Clinic* configuration, a smoke instance sharing the real app's preferences, is gone.
- **The data directory's name comes from the Info.plist key `ClinicDataDirectory`**, read once by
  `ClinicPaths.directoryName`. Every path that said `"Clinic"` goes through it. A process without the key, such
  as a test runner, gets `Clinic`. `CLINIC_APP_SUPPORT` still moves the parent directory for smoke runs.
- **The launch environment is bare**: `env -i` with `HOME`, `USER`, `SHELL`, `TMPDIR` and the system `PATH`,
  through `open`. That is what a Finder launch has, and tools are found through the login shell (ADR-086).
- **Clinic Dev never registers the wake agent.** The bundled plist has one launchd label and names
  `/Applications/Clinic.app`. `clinic-wake` now reads the bundle id and data directory of the app it ships in.
- **Clinic Dev wears an orange DEV band on its Dock icon** while it runs.
- **`~/.claude` is shared by default**, because a dev session needs the real login to talk to the API, and
  Clinic does not write there (ADR-018). `CLINIC_DEV_CLAUDE_CONFIG_DIR` gives it a config directory of its own
  for work that installs plugins or marketplaces.

## Consequences
- The dev loop no longer needs `CLINIC_APP_SUPPORT`, defaults clean-up, or picking a pid by its environment:
  `pgrep -x "Clinic Dev"` is the dev app. Smoke instances remain for scripted, throwaway runs.
- Clinic Dev starts empty: no projects, no owned sessions, its own notification permission and usage consent.
- Sessions Clinic Dev starts write transcripts to the shared `~/.claude/projects`. The real app lists only
  sessions it owns (ADR-048), so they appear there only as importable.
- Log lines from both apps share the `com.r0adkll.clinic` subsystem. Filter by process to separate them.
- `build/dev` is a second full build of the packages, a one-time cost in time and disk.
- The release build, `make build`, `make screenshots` and Xcode's Run are unchanged: they take the defaults.
- Verified 2026-10-02, with the real Clinic running and hosting the session: `make dev-build` produced
  `Clinic Dev.app` signed as `com.r0adkll.clinic.dev`. Launched, it bound `hook.sock` and `mcp.sock` in
  `Application Support/Clinic Dev`, wrote preferences only to its own domain, and carried no `CLAUDE_*`
  variable. A one-prompt haiku session in it delivered `SessionStart`, `UserPromptSubmit` and `Stop` through
  the helper path that contains a space. The real app's directory listing, socket and preferences file were
  unchanged before and after. `make build` still produces `Clinic.app` as `com.r0adkll.clinic` with data
  directory `Clinic`, and ClinicCore's 586 tests pass. Not seen: the DEV band on the Dock icon, because this
  machine gives the session no screen capture.
- Verified 2026-10-02: `scripts/dev attached` built, ran the app as its child with no `CLAUDE_*` variable and
  its own data directory, and the app was gone after its process was ended. Not run: the configuration from
  Clinic's Run pill.
