---
status: accepted (2026-10-17)
date: 2026-10-17
amends: "[[ADR-224 Emulators Run In A Device Pane]] (only running emulators were offered, and a tab whose emulator stopped retried for ever)"
tags: [adr, ui, tabs, runs, android]
---
# ADR-226: Emulators are started and stopped from Clinic

## Context
User (2026-10-17), after trying [[ADR-224 Emulators Run In A Device Pane]]: *"we probably need either an additional
panel or some other UI/UX experience for managing running emulators. Its not obvious how to start one or close one,
and when closing one the current emulator panel shows as "disconnected" vs better handling of the state"*.

Three directions and the stopped states were mocked on a canvas from this Mac's AVDs
(https://claude.ai/artifact/FkdLiuKRJwgRQ5wCxTv63c):
- **A**: a Devices pane listing every AVD.
- **B**: Start and Stop in the toolbar's device capsule ([[ADR-124 Runs Get A Device Ready]]).
- **C**: every AVD in the `+` menu, managed from its tab.

## Options
Put to the user as one Grill round, 2026-10-17. Every recommendation was taken, shown in bold.

| Question | Options |
|---|---|
| Where emulators are started and stopped | **C, plus Start/Stop in the capsule**; A: a Devices pane; B only; C only |
| What a tab shows when its emulator stops | **Close it if you stopped it; otherwise "off" with Start and Close Tab**; always keep it; always close it |
| Do Device tabs survive the emulator restarting? | **Yes, it reconnects by AVD**; a new tab each boot |
| Extra boot options | **Cold Boot**; **Wipe Data… (with a confirmation)**; Show in Finder; create and edit AVDs |

## Decision
- **Every AVD is offered**, running or not: the `+` menu's *Devices* section and the empty panel's.
  - The list comes from `emulator -list-avds`, every 30 seconds.
  - Each row says whether the AVD is open, running, starting, or not running.
  - Choosing one that is not running starts it with its window hidden and opens its tab, which shows
    *Starting …* until the emulator appears.
  - *More Devices* in the `+` menu starts a stopped AVD cold (`-no-snapshot-load`), or wiped (`-wipe-data`).
    Wiping asks first.
  - Creating and editing AVDs stays in Android Studio.
- **The capsule's popover** puts Start (▶) or Stop (■) beside each emulator.
  - Neither one chooses the emulator as the run's device.
  - A start follows *Show emulators in Clinic*: with it on, the emulator has no window and its tab opens.
- **Stopping** shuts the emulator down over gRPC. One still running 20 seconds later, or unreachable, is killed
  with `adb emu kill`.
  - Stopping from the tab's ⋯ ▸ Stop Emulator shows *Shutting down …* over the dimmed last frame, and closes the
    tab once the emulator has gone.
- **A tab whose emulator stopped some other way stays**, and says so instead of retrying:
  - *‹name› is off · Stopped at ‹time›* with Start and Close Tab, when it shut down (Android Studio,
    `adb emu kill`).
  - *‹name› quit* with Start Again and Cold Boot, when it exited without shutting down.
  - *‹name› is off* with no time, when it has not run since the tab opened.
  - An emulator removes its discovery file when it shuts down. So once its process has gone, a file left behind
    means it quit.
- **Tabs reconnect by AVD**, as before: a kept tab goes live again whenever that AVD boots, however it was started.

## Consequences
- `EmulatorDirectory` holds the AVDs, the starts and stops Clinic asked for, and how each AVD last ended. While a
  start or stop is pending, it rescans every second.
- ClinicCore: `RunDeviceProbe.avds`, `startEmulator`, and `emulatorArguments(coldBoot:wipeData:)`, with tests.
- AndroidEmulator: `RunningEmulator.leftDiscoveryFile()`.
- Checked in Clinic Dev:
  - Choosing a stopped AVD from `+` booted it into a new tab, which went live.
  - Stop Emulator showed *Shutting down …*, then closed the tab.
  - `adb emu kill` left *is off · Stopped at 3:47 PM* with Start and Close Tab.
  - `kill -9` was logged as a quit.
- Not checked by hand:
  - the off state's Start button (the window left accessibility; it shares the start path the `+` menu used);
  - the capsule's buttons;
  - Cold Boot and Wipe Data.
- A start Clinic makes is not read-only. Like Studio's, it saves the quick-boot snapshot when it shuts down.
