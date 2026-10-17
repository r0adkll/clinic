---
tags: [research, android, emulator, spike, panel]
date: 2026-10-17
sources: [~/Library/Android/sdk/emulator/lib/emulator_controller.proto, ~/Library/Caches/TemporaryItems/avd/running/pid_*.ini]
---
# Embedding the Android emulator in a panel — spike

User (2026-10-17): "It would be nice if we could embed / render the Android emulator in a panel like in Android
Studio… show/hide the panels without having to obscure or hide clinic to see it."

**Verdict: feasible, and the same way Android Studio does it.** Studio does not reparent the emulator's window (macOS
cannot host another process's window). It launches the emulator with its window hidden and draws the screen itself
over the emulator's gRPC `EmulatorController` service, sending input back the same way. Everything below was measured
on this Mac against emulator 36.6.11 (build 15507667), API 36 arm64 images, with a Python gRPC client.

## How Studio does it
- Studio's own running emulator on this Mac: `qemu-system-aarch64 -avd Pixel_10_Pro_Fold -qt-hide-window
  -grpc-use-token -idle-grpc-timeout 300`. `-qt-hide-window` keeps the full emulator (not the `-headless` binary) but
  never shows its Qt window. `-idle-grpc-timeout` exits it once no gRPC client has been attached for that long.
- **Discovery:** every running emulator writes `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini` with
  `avd.id`, `avd.name`, `port.serial` (so `emulator-<port>`), `port.adb`, `grpc.port` and `grpc.token`. Headless
  `-no-window` emulators write one too, and expose gRPC with a token, without `-grpc` being passed.
  **Match on `avd.id`:** the serial is reassigned on every boot (`campfire-shots-phone` came up as 5558, then 5556),
  and during the spike a probe aimed by serial order hit the wrong device. The `pid_` in the name is the `qemu`
  process (an earlier draft of this note said otherwise; that was a misread of interleaved grep output).
- **Auth:** `authorization: Bearer <grpc.token>` worked for every call used here. Methods are gated by
  `emulator/lib/emulator_access.json`.
- **API:** `emulator/lib/emulator_controller.proto` ships in the SDK. The calls a panel needs are:
  `streamScreenshot(ImageFormat) → stream Image`, `sendTouch`, `sendMouse`, `injectWheel`, `sendKey` (key codes or
  `text`), `getStatus`, `getDisplayConfigurations`, `setPosture` (folds), `setClipboard`/`streamClipboard`,
  `streamNotification`. It also has logcat, audio, sensors, GPS, battery, SMS and VM state, which are useful later.

## Measurements
Device `campfire-shots-phone`, 1080×2160, Settings being flung continuously by `sendTouch` from a second thread.

| Request | Frame | fps | Bytes over the socket |
|---|---|---|---|
| RGBA8888, full size | 1080×2160 | 59.3 | 553 MB/s |
| RGB888, half size | 540×1080 | 59.8 | 105 MB/s |
| PNG, full size | 1080×2160 | 24.4 | 6 MB/s |
| RGBA8888, full size, `MMAP` transport | 1080×2160 | 59.3 | ~0 (pixels land in a shared file) |

- `streamScreenshot` pushes **only when the screen changes**. An idle screen gave 3–4 fps, so an idle panel costs
  almost nothing.
- `getScreenshot` of a full PNG took 57 ms. That's fine for thumbnails or a sidebar card.
- **Touch → first changed frame:** 47–67 ms (half-size RGB888 stream, five trials), including Android's own touch
  slop and render. Studio feels like this too. The gRPC hop is not the bottleneck.
- **`MMAP` is the path to use.** It took the full 60 fps at full resolution with nothing on the socket. The
  `ImageTransport.handle` is `file://<path>`, a file Clinic creates at exactly `width × height × 4` bytes. Each
  `Image` message then carries only the format and sequence number, and the pixels are read from the mapped file.
  That can go straight into an `IOSurface`/`MTLTexture`, or a `CALayer`'s contents.

## A crash to design around
The first `MMAP` attempt killed a headless emulator (`campfire-testbed`, `-no-window`). The connection was reset and
the process exited (`.ips` 2026-10-17 09:14:53, aborting in gRPC teardown during `exit`). That request sent
**no width/height** and a file padded **4 KB past** the frame size. A later identical-transport request to the same
AVD, relaunched, with **explicit width/height and an exactly sized file**, worked at 43 fps. It's not proven which
difference mattered. Until it is, Clinic should:
- always send explicit `width`/`height` computed from `getStatus`/`getDisplayConfigurations` and the pane's size,
  and size the file to match;
- re-create the file and restart the stream when the display size changes (rotation, fold, resize);
- fall back to RGB888 bytes at pane resolution, which is cheap at panel sizes (a 400 pt-wide retina pane is ~800 px
  wide, about 1/3 of the full frame), if a stream drops or the emulator vanishes after an `MMAP` request.

## What it would take in Clinic
- **Pane kind:** a *Device* pane in the session workspace ([[ADR-212 A Session Is A Workspace Of Tabs]]), opened
  from the `+` menu ([[ADR-213 The Plus Menu Replaces The Openers]]) and by a run whose configuration names an
  emulator ([[ADR-124 Runs Get A Device Ready]]). It is one per device, and could belong to the project or checkout
  rather than one session, like run panes.
- **Discovery and attach:** watch `avd/running/` and offer every running emulator, including Studio's and headless
  ones. Attach with the token. Nothing has to be launched by Clinic.
- **Boot:** `RunDevices` boots with plain `-avd <name>` today (`ClinicCore/Run/RunDevices.swift`), which opens the
  emulator's own window. To embed, boot with `-qt-hide-window -grpc-use-token`, plus `-idle-grpc-timeout` if Clinic
  should own its lifetime. That is a behaviour change (no standalone window), so it needs an ADR and probably a
  setting.
- **Dependency (ADR-058):** grpc-swift 2 (`grpc-swift-2`, `grpc-swift-nio-transport`, `grpc-swift-protobuf`) plus
  `swift-protobuf`. They're Apache-2.0, SwiftPM, and require macOS 15, which matches `project.yml`. The client is
  generated from the SDK's proto and lives in the app target or a new package; `ClinicCore` stays Foundation-only.
  The only non-gRPC alternatives are the telnet console and `adb screencap`/`screenrecord`, which are not real-time.
- **Rendering:** a `CAMetalLayer` or IOSurface-backed `NSView` showing the mapped frame, aspect-fit, with a
  device-frame/skin optional and out of scope at first.
- **Input:** mouse → `sendTouch` (pressure 1/0, identifier 0) with pane→device coordinate scaling. Wheel →
  `injectWheel`. Keyboard → `sendKey`, using `text` for typed characters and key codes for arrows, Enter, Back and
  Home. Pinch could come from the trackpad's magnify gesture as two touch identifiers. A small toolbar would carry
  Back, Home, Overview, rotate, volume and screenshot. Clinic's keymap must step aside while the pane has focus
  (like [[ADR-135 The Grill Pane Owns Its Keyboard]]).
- **Foldables and rotation:** `Image.format` carries rotation and `foldedDisplay`. `setPosture` folds and unfolds.
  The Pixel Fold AVDs on this Mac need this.

## Rough size
- **MVP** (attach to a running emulator, RGB888 at pane size, mouse/wheel/keys, Back/Home): a few days, most of it
  the gRPC dependency and code generation.
- **Studio-grade** (`MMAP` into Metal, rotation, folds, multi-display, clipboard sync, boot hidden from runs,
  lifetime ownership): another 1–2 weeks.
- **Physical devices** are a separate project. Studio pushes a screen-sharing agent to the device; scrcpy is the
  open alternative (Apache-2.0, H.264 over adb). Out of scope here.

## Prototype (2026-10-17)
Built in the `zazzy-drifting-parasol` worktree to try the idea in Clinic Dev:
- `Packages/AndroidEmulator`: the client generated from the SDK proto (protoc 36.2, protoc-gen-swift 1.39.0,
  protoc-gen-grpc-swift-2 from grpc-swift-protobuf 2.5.0, checked in, regenerated by
  `scripts/generate-emulator-grpc.sh`), `RunningEmulator` (discovery), and `EmulatorConnection` (frames
  through `MMAP`, input down one ordered `streamInputEvent` stream). grpc-swift 2.4.4, nio-transport 2.11.0,
  grpc-swift-protobuf 2.5.0, swift-protobuf 1.39.0. nio-transport also brings in swift-nio-ssl (BoringSSL), unused
  over plaintext localhost but compiled.
- A `device(avdId)` pane kind (`Sources/Clinic/DevicePane.swift`): running emulators are offered in the `+` menu
  and in a *Devices* section of the empty panel. The pane draws aspect-fit frames requested at the pane's pixel
  size, maps clicks and drags to one finger, sends the wheel and Mac key codes, and has Back, Home and Recent
  Apps under the screen. It streams only while on screen.
- Hidden seam `-ClinicOpenDeviceOnLaunch <avd id>` opens it in the launch tab's panel.
- **Seen working in Clinic Dev:** the live screen in the right panel, updating as the device changes. The Home
  button sent `GoHome` (adb then showed the launcher in front). The package's live test streamed a frame.
- **Not yet checked in the app:** click, drag, scroll and typing. Touch over gRPC was measured in the spike,
  but the pane's coordinate mapping has not been exercised.

## Not tested
Typed text and key events, rotation and fold, two clients at once (Clinic and Studio's panel viewing the same
emulator), a Swift gRPC client, audio, multi-display, CPU cost of a Swift renderer. Swift and two-client viewing
are the next things to try in a prototype.
