---
status: accepted
date: 2026-09-09
tags: [adr, notifications, ui, preferences]
---
# ADR-097: Notification sounds are your own files, played in rotation

## Context
User request 2026-09-09. [[ADR-033 Notification Delivery]] said "no sound by default" and the
implementation grew one boolean, `ClinicNotificationSound`, feeding two unrelated noises:
`UNNotificationSound.default` on the system-notification path and `NSSound(named: "Ping")` on the
in-app card path ([[ADR-066 Attention]]). One switch, two sounds, neither chosen by the user.

Wanting your own sound is not a cosmetic ask. Clinic's notifications all mean "a session wants
you", and a user who runs several sessions all day learns a sound the way they learn a ringtone.
Several sounds in rotation carry more: consecutive notifications are audibly distinct, so two in a
row do not read as one.

## Decision
- **A sound list, not a sound.** The Notifications preference pane holds an ordered list of local
  audio files. `ClinicNotificationSound` stays as the master on/off, so the existing preference
  survives untouched; the list is a new key, `ClinicNotificationSoundFiles`.
- **Empty list = today's behaviour, exactly.** `.default` on the system path, `Ping` in-app. Adding
  the first file is the only thing that changes delivery.
- **Round-robin, in list order.** Each notification that sounds takes the next entry and advances.
  Order is the list's order and is drag-reorderable. The cursor lives in memory and starts at the
  top each launch — a persisted cursor buys nothing you would notice, and it would be one more
  `UserDefaults` key shared with smoke instances ([[ADR-038 Preferences and Diagnostics]] amendment).
- **Clinic plays custom files itself, on both delivery paths, and posts the system notification
  silent.** `UNNotificationSound` can only name a file in the app bundle or `~/Library/Sounds`; an
  arbitrary path cannot be handed to it, and Clinic will not copy user audio into `~/Library/Sounds`
  to work around that. Clinic is by definition running at the moment it posts, so it can play the
  file. Silencing the notification is what stops the sound doubling.
- **The consequence is Focus.** A system notification's sound is suppressed by Do Not Disturb;
  `AVAudioPlayer` is not. So with custom sounds chosen, notifications keep sounding through Focus.
  That is the honest cost of arbitrary files, and it applies only to a list the user built on
  purpose — the empty-list default still routes through the system and still respects Focus.
- **Files are referenced, never copied.** The list stores paths. A file that has moved or become
  unreadable is shown as missing in the list, is skipped by the rotation, and if *every* entry is
  missing the rotation falls back to the default sound rather than going quiet — a notification
  that makes no noise is indistinguishable from a notification that never fired.
- **Two test actions, because there are two things to doubt.** A ▶ on each row plays that file, to
  answer "is this the file I meant"; a **Test Notification** button in the pane fires a real
  notification through `TabStore.notify`, to answer "is this what I will hear". The test takes the
  full router — history row, card or system notification, rotation advance — because a test that
  used a private shortcut would be testing something other than the thing it is trusted to test.

## Consequences
- `NotificationSounds` (ClinicCore, Foundation-only) owns the list, its codec and the rotation, so
  wraparound, skipping and the all-missing fallback are unit-tested without a speaker.
  `NotificationSoundPlayer` (app target) owns `AVAudioPlayer` and is the single place that decides
  whether a notification sounds — `TabStore.notify` no longer plays anything itself.
- `NotificationService.post` gains `silent:`; the caller, not the poster, knows whether Clinic has
  already made the noise.
- The preference pane can now be reached by a rotation the user cannot hear (all files missing after
  a disk move). The missing badge in the list is the only warning; there is no notification about
  notifications.
