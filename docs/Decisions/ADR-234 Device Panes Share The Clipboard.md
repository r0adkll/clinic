---
status: accepted (built 2026-11-08)
date: 2026-11-08
amends: "[[ADR-224 Emulators Run In A Device Pane]] (clipboard sync is no longer deferred, and four ⌘ chords now reach the device)"
tags: [adr, ui, runs, android]
---
# ADR-234: Device panes share the clipboard

## Context
User (2026-11-08): *"Does our emulator view allow copy/paste of text?"* It did not. [[ADR-224 Emulators Run In A
Device Pane]] deferred clipboard sync and kept every ⌘ chord for Clinic's menus. So ⌘C and ⌘V never reached the
device, and text could not cross between the Mac and the emulator in either direction. In a windowed emulator the
emulator's own window shares the clipboard. A pane that replaces that window had to do the same. The user: *"we
need to add support for clipboard sync and copy/paste commands"*.

The emulator's gRPC `EmulatorController` has `setClipboard`, `getClipboard` and `streamClipboard`. Android Studio's
Running Devices panel uses them to sync the clipboard. Measured against a headless emulator (36.6.11) while building
this:
- `setClipboard` from one connection reaches another connection's stream, and the device's own Paste.
- A copy made on the device reaches every stream.
- A Control-V sent at once after `setClipboard` returns pasted the new text every time (6 of 6).
- The stream opens with what the device holds, **but only when that is not empty**. A client cannot tell that
  first message from a real copy, so it has to read `getClipboard` first.
- Mac key code 0 is A, and 0 is protobuf's default, so the key code is never written to the wire. The emulator
  dropped every A typed in the pane, and so every Control-A, since ADR-224.

## Decision
- **Text on the clipboard is shared both ways while a Device pane is connected.** Only text, because `ClipData`
  carries nothing else.
  - **Device → Mac.** Each pane's connection streams the device's clipboard. A copy made on the device replaces
    the Mac's clipboard with its text. What the device already holds when the pane connects is only remembered,
    so opening a pane never replaces what the user copied on the Mac.
  - **Mac → device.** The Mac's clipboard text goes to the device when the user uses the pane: on each click or
    key the screen takes, if the Mac's clipboard changed since the pane last looked. The device's own Paste
    (long-press ▸ Paste) then has it too. A device the user is not touching never receives the Mac's clipboard.
  - Each pane remembers the device's text and the Mac pasteboard's change count. Echoes are dropped in both
    directions. Two panes on one emulator both hear a copy, and the second finds the text already there.
- **Edit ▸ Cut, Copy, Paste and Select All reach the device** while its screen has the keyboard. These are ⌘X,
  ⌘C, ⌘V and ⌘A, or whatever the Edit menu is bound to. The screen view answers the Edit menu's `cut:`, `copy:`,
  `paste:` and `selectAll:` actions and sends the device the Control chord for each. Android text fields, in both
  views and Compose, take these chords from a hardware keyboard. The chord waits for any push of the Mac's
  clipboard to finish, plus 50 ms in case the guest is slow, so ⌘V pastes what the Mac just copied. Every other
  ⌘ chord stays Clinic's.
- **A goes to the device as its Linux evdev code (30)**, not Mac key code 0. Every other key stays a Mac key code.
- **Settings ▸ Sessions ▸ Runs ▸ *Share the clipboard with emulators*,** on by default, like Android Studio's
  clipboard sharing. It is read at each use, so turning it off stops both directions at once. The Edit commands
  still reach the device with it off, and then use only the device's own clipboard.

## Consequences
- `EmulatorConnection` gains `setClipboard`, `clipboardText`, `clipboard()` (the stream) and `controlChord`. Its
  `key(macKeyCode:)` sends A as evdev.
- A live test, `clipboardReachesAnotherConnection`, runs only with `CLINIC_TEST_CLIPBOARD` set as well as
  `CLINIC_TEST_AVD`, because it replaces the device's clipboard.
- A copy made on the device replaces the Mac's clipboard even when it holds an image or a file, as Android
  Studio's sync does. That includes a copy an app makes in the background while a pane is open.
- The pane's connection lives while its tab is open, even off screen. Copies made on the device keep reaching the
  Mac until the tab closes.
- Typed A, which was lost since ADR-224, now reaches the device.
- **Checked:** against a headless `campfire-shots-phone`, on one connection, by reading the focused field over
  `uiautomator` after each step: typed `a`, Control-A, Control-C (seen by `getClipboard`), Control-X and Control-V
  after `setClipboard`. The other live tests pass, and Clinic Dev builds.
- **Not checked in the app.** Synthetic clicks are refused to this session, so the Edit menu reaching the pane and
  the Mac pasteboard updating were not driven by hand. To check: open a Device pane, focus a text field on the
  device, copy text on the Mac, click the screen and press ⌘V. Then select the text on the device, press ⌘C, and
  paste into a Mac app.
