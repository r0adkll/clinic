---
status: accepted
date: 2026-09-11
amends: ADR-122 (a `device` field, a preparing step, the set-up prompt); builds the destination picker ADR-122 deferred
tags: [adr, ui, runs, android, ios]
---
# ADR-124: Runs get a device ready

## Context
User (2026-09-11): *"one thing I noticed with AI configured Android run configurations is that it
doesn't take into consideration active device or emulator setups. If we are trying to replicate the
environment from Android Studio (for example) then it needs to boot an emulator if no device is
connected to be effective"*

A configuration from [[ADR-122 Projects Have Run Configurations]] is a bare shell command.
`./gradlew :app:android:installAlphaDebug` with nothing attached fails with "No connected
devices". Android Studio never lets that happen: its toolbar carries a device selector beside the
run configuration, and running an emulator that is not booted boots it first. Xcode does the same
with simulators. ADR-122 deferred "a typed Xcode configuration kind with a simulator or device
destination picker".

**What this machine has** (checked 2026-09-11):
- The SDK is at `~/Library/Android/sdk`, with six AVDs, including three `campfire-shots-*`, and
  nothing attached.
- There are 44 available simulators across four iOS runtimes.
- `simctl bootstatus <udid> -b` boots a simulator and blocks until it is ready.
- `adb -s emulator-NNNN emu avd name` maps a running emulator to its AVD.

## Options
Put to the user, 2026-09-11. The chosen answer is in bold.

| Question | Options |
|---|---|
| Where is the device chosen? | **A device capsule in the toolbar beside the Run pill**; a section in the Run popover; automatic only |
| Which platforms? | **Android and the iOS Simulator**; Android only |

## Decision
- **A configuration can name its device**: `"device": "android"` or `"device": "ios"` in
  `run.json`.
  - An unknown value (a newer Clinic's) reads as none, rather than failing the file.
  - The editor sheet has a *Device* picker.
  - Detection and import set it from the command: an install task or `adb` means Android;
    `simctl`, an iOS Simulator destination or `SIMULATOR_UDID` means iOS.
- **Clinic gets the device ready before the command runs**, and names it in the environment:

  | Platform | Variable | Who reads it |
  |---|---|---|
  | Android | `ANDROID_SERIAL` | Gradle's install tasks and `adb` read it themselves |
  | iOS | `SIMULATOR_UDID` | The command passes it on (`-destination "id=$SIMULATOR_UDID"`, `simctl install/launch`) |

  - **Android.** A connected device, or a running emulator, is used as it is. An AVD that is not
    running is started with `emulator -avd <name>`, detached, so it outlives the run as Android
    Studio's do. Clinic then polls `adb devices` until an emulator reports that AVD's name, then
    polls `getprop sys.boot_completed` until it reads `1`. The limit is 4 minutes.
  - **iOS.** `xcrun simctl bootstatus <udid> -b`, then `open -a Simulator` on that device.
  - **The SDK** comes from the project's `local.properties`, then `ANDROID_HOME` /
    `ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`. A GUI app does not inherit the shell's
    `ANDROID_HOME`.
- **The run shows the step.** Until the terminal exists, the run is *running* with a `preparing`
  message ("Starting Pixel 10 Pro Fold…", "Waiting for … to finish booting…"). The pane shows it
  with a spinner and *Cancel*, and the pill spins as for any running run.
  - **Stop** cancels the waiting, not the boot.
  - **Two runs that need the same emulator** wait on one boot.
  - **If no device can be found or booted**, the run fails without an exit code. Its `problem` is
    shown in the pane with *Try Again*, and in the notification.
  - **The pane header** names the device the run targets.
- **The device capsule** sits between the Run pill and Open In ([[ADR-123 Toolbar Choices Open
  In Popovers]]'s glass), one per platform the selected configuration needs.
  - **Its label** is the device the next run uses. The icon is dimmed when the device is not
    running.
  - **Its popover** lists Android devices as *Connected* (serial, or *running* for an emulator),
    then *Emulators* (*boots*). iOS simulators are listed *Booted*, then by runtime, newest first.
    An unauthorized device is shown, disabled, with the reason. *Refresh* lists again.
  - **The choice** is kept per project and platform, in `state.json` (`runDeviceByProject`), never
    in the repo.
  - **With no choice**, or a remembered device that is gone, the capsule falls back: a running
    device first, then the first emulator. For iOS, it is the newest runtime's newest iPhone
    ("iPhone 17" before "iPhone 16e").
- **The set-up prompt** tells Claude to set `device`, and not to boot emulators or pick devices in
  the command. `list_run_configurations` says which device a configuration installs onto, and
  `read_run_output` reports a preparing step or a problem.

## Consequences
- **ClinicCore `Run/RunDevices.swift`:**
  - the types: `RunDevicePlatform` (with `inferred(fromCommand:)`), `RunDevice`, `RunDeviceError`;
  - the parsers: `AndroidSDK`, `AndroidDevices` (`adb devices -l`, `-list-avds`, `emu avd name`),
    `IOSSimulators` (`simctl list -j`);
  - `RunDeviceChoice`, and `RunDeviceProbe`, which lists and prepares, with every subprocess
    bounded.
  - `RunDeviceTests` holds the parser and choice tests.
- **App**: `RunDeviceStore`, `RunDeviceControl` and `RunDevicePopover` (`RunDeviceViews.swift`).
  `Run` gains `preparing`, `problem` and `device`, and `RunStore.begin` puts the device step in
  front of `launch`.
- **Checked on real hardware** (a throwaway opt-in test, deleted afterwards):
  - Android listed all six AVDs, booted *Pixel 10 Pro Fold* in 12 s, returned
    `ANDROID_SERIAL=emulator-5554`, and listed it as running afterwards.
  - iOS booted a simulator and returned its UDID.
  - Both were shut down afterwards.
- **Not yet checked in the app itself.** The display was asleep, and libghostty cannot create a
  surface then (`ghostty_surface_new failed`).
- **Smoke key**: `-ClinicToolbarPopoverOnLaunch device` opens the device popover.
- **Deferred:**
  - physical iOS devices (`devicectl`);
  - Wear OS, TV and watchOS targets;
  - choosing a device per run rather than per project;
  - stopping or wiping an emulator from the popover;
  - cold boot.
