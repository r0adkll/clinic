---
status: accepted (built 2026-10-15)
date: 2026-10-15
amends: "[[ADR-199 Clinic Plays OpenPeon Sound Packs]] (pack lines no longer always play through Focus), [[ADR-097 Notification Sounds]] (nor does the notification sound)"
tags: [adr, sounds, notifications, focus]
---
# ADR-207: A Focus filter quiets Clinic's sounds

## Context
User (2026-10-15): *"for 3 let's add a focus status permission/setting."* [[ADR-199 Clinic Plays OpenPeon Sound Packs]]
left Focus for later. Clinic plays its own sounds, pack lines and the notification sound alike
([[ADR-097 Notification Sounds]]), so a Focus that silences notifications never silenced them.

There are two public ways for an app to learn about Focus:
- **The Focus Status permission** (`INFocusStatusCenter`). It needs the `com.apple.developer.focus-status`
  entitlement. Clinic is signed today with no provisioning profile, and a trial build with the entitlement failed:
  *"No profiles for 'com.r0adkll.clinic' were found"*. Adopting it means enabling the capability on both App IDs,
  provisioning profiles for Debug, Clinic Dev and Developer ID, and `-allowProvisioningUpdates` in every build
  script. It is also not confirmed that Developer ID profiles allow it.
- **A Focus filter** (`SetFocusFilterIntent`, App Intents). It needs no entitlement. The user adds the app's filter
  to a Focus in System Settings, and the system tells the app when that Focus starts and ends.

Asked, the user chose the filter, and chose to quiet both pack lines and the notification sound.

## Decision
- **Clinic offers a Focus filter, *Clinic Sounds*,** with one switch, *Sounds*, on by default. Switching it
  off in a Focus's filter keeps Clinic quiet while that Focus is on. Each Focus decides for itself.
- **Quiet means no sound:** no pack line, and no notification sound, on the card or in the system notification
  (posted silent). Cards, history, badges and banners carry on. A ▶ the user presses still plays.
- **The default must be the ordinary state.** The system calls `perform` with the defaults when the Focus ends, so
  *Sounds on* is the default and the user switches it off.
- **A launch during such a Focus starts quiet**: `ClinicFocusFilter.current` is read at launch. It throws when no
  active Focus uses the filter, which reads as sounds on.
- **The Sounds screen says so.** The Events section gains *Quiet during a Focus*, explaining the filter, with a
  *Focus Settings…* button that opens System Settings ▸ Focus. While quiet, the row reads *Quiet for a Focus*,
  and the footer shows a moon and the same words. The old footer line, "Packs play through Focus", is gone.
- `FocusQuiet.shared` holds the state. `TabStore.voice` voices nothing while quiet, and `TabStore.notify`
  skips the notification sound.

## Consequences
- The filter cannot name which Focus asked for quiet; Clinic says only "a Focus".
- The pack router's cooldowns and no-repeat memory do not advance while quiet, since nothing is decided.
- `-ClinicFocusQuiet YES` starts Clinic as if a Focus had asked for quiet, for checks.

## Verification
- `make build` passes. The bundle's `Metadata.appintents/extract.actionsdata` lists `ClinicFocusFilter`
  (*Clinic Sounds*, parameter `sounds`) under `com.apple.link.systemProtocol.FocusConfiguration`.
- The row was rendered from its real source in a throwaway SwiftUI harness inside a grouped form: icon, title,
  two-line explanation and button sit in one row at 720 pt.
- `com.apple.Focus-Settings.extension` is the Focus pane's bundle id on this Mac (macOS 26).
- **Not driven:** a real Focus turning on and off, which would change the user's Focus setup. Also unchecked:
  whether the system launches Clinic to deliver a filter when it is not running. Manual check:
  1. `make dev`, then System Settings ▸ Focus ▸ (a Focus) ▸ Focus Filters ▸ Add Filter ▸ Clinic Dev ▸ Clinic
     Sounds, and switch Sounds off.
  2. Turn that Focus on: the Sounds footer shows the moon, and a finished turn in a background tab is silent.
  3. Turn it off: the next finished turn speaks again.
