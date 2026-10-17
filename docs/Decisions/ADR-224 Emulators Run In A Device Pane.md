---
status: accepted (2026-10-17)
date: 2026-10-17
amends: "[[ADR-124 Runs Get A Device Ready]] (an emulator a run boots has no window of its own)"
tags: [adr, ui, tabs, runs, android]
---
# ADR-224: Emulators run in a Device pane

## Context
User (2026-10-17): *"It would be nice if we could embed / render the Android emulator in a panel like in Android
Studio. This makes it nicer to debug and show/hide the panels without having to obscure or hide clinic to see
it."* A spike ([[Embedded Android Emulator]]) found that Android Studio's Running Devices panel never hosts the
emulator's window. It starts the emulator with the window hidden (`-qt-hide-window -grpc-use-token`), draws the
screen it streams over the emulator's gRPC `EmulatorController`, and sends input back the same way. Measured on
this Mac: 60 fps at full resolution through the shared memory transport, and 47–67 ms from a touch to a changed
frame. A prototype pane worked in Clinic Dev. Then the user, on the shippable design: *"Their own connection
sounds like the more scalable solution … if we are launching emulators via Clinic we should default to this
headless/panel view … we should aim to supply all the same controls that Android Studio does, probably all of
them in a toolbar at the top of the emulator … punt physical devices for a future effort. The panel should also
support multiple emulators (and later physical devices)."*

## Decision
- **A Device pane kind** in the session workspace ([[ADR-212 A Session Is A Workspace Of Tabs]]), keyed by the id
  runs already use for a device: `avd:<id>` for an emulator, since the serial changes on every boot. A physical
  device can later be its serial. It can go in either area and be dragged like any pane.
- **Any number of devices.** Each running emulator is its own pane and tab, and several can be open side by side,
  in one session or across sessions.
- **Each pane holds its own connection** to its emulator, so two panes showing one emulator are two clients.
  The screen streams only while the pane is on screen, and frames are requested at the pane's pixel size.
- **Running emulators are found, not launched.** Every emulator writes
  `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini` with its gRPC port and token. Clinic offers each
  one from the `+` menu and the empty panel's *Devices* section, including Android Studio's and headless ones.
- **Two ways in.** An emulator started with `-grpc-use-token` takes the token from its discovery file. Every other
  one, Android Studio's included, takes only signed JWTs (`-grpc-use-jwt` is the default). For those, Clinic puts a
  P-256 public key, as a JWK set, in the emulator's `grpc.jwks` directory, waits for `grpc.jwk_active` to list it,
  and signs a ten-minute ES256 token per call with issuer `android-studio`, which the SDK's
  `emulator_access.json` allows every service the pane calls. Tink, the emulator's validator, refuses a `typ`
  header and a bare JWK (not a set).
- **An emulator a run boots has no window** (amends [[ADR-124 Runs Get A Device Ready]]). It starts with
  `-qt-hide-window -grpc-use-token`, and its Device pane opens and is fronted in the run's tab. One already
  running is left as it is. Settings ▸ Sessions ▸ Runs ▸ *Show emulators in Clinic* turns this off, on by default.
- **Android Studio's controls in a toolbar over the screen**, in Studio's order: Power, Volume Up, Volume Down ·
  Rotate Left, Rotate Right, Fold (foldables) · Back, Home, Overview · Take Screenshot, Record Screen, Snapshots ·
  ⋯ (Hold Power, Extended Controls…, Stop Emulator). Groups that do not fit the pane's width fold into ⋯, capture
  first, then hardware, then orientation; navigation always stays.
- **Captures go where macOS puts screenshots** (`com.apple.screencapture location`, else the Desktop), named
  `<device> Screenshot <date> at <time>.png` or `… Screen Recording ….webm`. A notice over the screen offers *Show
  in Finder*. Recording uses the emulator console's `screenrecord`, as Studio does, since gRPC has no call for it.
- **Input:** a click or drag is one finger, the wheel scrolls, and keys typed while the pane has the keyboard go
  to the device as Mac key codes; ⌘ chords stay Clinic's. Touches are turned back from the screen's rotation and
  a folded foldable's region, because the emulator takes them in the display's natural orientation.
- **Physical devices are deferred** to a later effort, as are multi-touch, clipboard sync and device frames.

## Consequences
- grpc-swift 2 and swift-protobuf join the app through a new local package, `Packages/AndroidEmulator`
  ([[ADR-058 Third-Party Packages Allowed]]). Its client is generated
  from the SDK's protos by `scripts/generate-emulator-grpc.sh` and checked in. `ClinicCore` stays Foundation-only.
- An emulator Clinic boots outlives the pane and the run, like a windowed one. A closed pane is reopened from `+`.
  The pane's Stop Emulator, or Android Studio, ends it.
- Without a window, the emulator's own UI is reached only through Extended Controls, which it opens on request.
- An `MMAP` request without explicit dimensions once killed a headless emulator. The client always sends the size,
  and sizes the shared file to match.
