---
status: accepted (built 2026-11-07)
date: 2026-11-07
amends: "[[ADR-124 Runs Get A Device Ready]] (a `showDevice` field) and [[ADR-224 Emulators Run In A Device Pane]] (a run's emulator is shown when the configuration asks, not only when the run booted it)"
tags: [adr, ui, runs, android]
---
# ADR-233: A run configuration can show its emulator

## Context
User (2026-11-07): *"when running a run configuration that configures an emulator, we should have a setting in the
run configuration that when checked will open the target emulator in the right panel, or bring it into focus when
the run is executed"*

Under [[ADR-224 Emulators Run In A Device Pane]], a run opens a Device pane only for an emulator it booted itself,
with no window. An emulator that was already running stays wherever it was. After the first run, every later run
of the same app leaves its screen out of sight, so the user has to open the emulator from `+` to watch the
install land.

## Decision
- **A configuration can ask to show its device**: `"showDevice": true` in `run.json`, beside `device`.
  - It is written only when true, like `rerunAfterTurn`.
  - It has no effect without a `device`.
  - It is left out of the trust fingerprint ([[ADR-122 Projects Have Run Configurations]]), because it changes
    nothing that runs.
- **The editor sheet** shows the checkbox *Show the emulator in the panel on each run* under the Device picker, for
  Android only. The iOS Simulator already comes forward on every run (ADR-124's `open -a Simulator`). A value
  written by hand on an iOS configuration is kept on save.
- **On each run**, once the device is ready and the command has started, an Android emulator's Device pane is
  shown. It goes in the tab hosting the run, else the tab the run was started from.
  - **Started by the user** (the Run pill, ⌘R, the menu), it behaves like any opener. It opens in the right panel,
    or is fronted where it already is, in either area.
  - **Started by Claude's `run` tool, or re-run after a turn**, it still comes forward in the right panel, but the
    keyboard stays where it was. A pane already in the main area is left behind the session, which the user may
    be typing into. Showing the screen is what the user asked for. Taking their typing is not
    ([[ADR-197 Only The Tab On Screen Takes The Keyboard]]).
  - A physical device has no pane yet, so nothing opens for one.
- **A configuration that shows its device boots it without a window**, even with *Show emulators in Clinic* off.
  Its screen is going in the panel anyway, and a window as well would show it twice.
- **ADR-224's rule still holds without the field.** An emulator a run boots without a window still opens its pane,
  now following the same rule for the keyboard.

## Consequences
- ClinicCore: `RunConfiguration.showDevice` and `showsDevice`, with a round-trip test.
- App: `Run.origin` records the starting tab and whether the user started the run. `RunStore.showDevice` picks the
  tab. `TabStore.showRunDevice` replaces `openDevicePane`.
- Before this change, a run Claude started that booted an emulator opened no pane unless the run was already on
  screen. Now it opens the pane in the right panel, without moving the keyboard.
- Not checked by hand. Clinic Dev builds and the ClinicCore tests pass, but no Android run has been made in the
  app.
- The Claude set-up prompt does not mention `showDevice`. Showing the emulator is the user's preference, not
  something the build implies.
