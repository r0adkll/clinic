---
status: accepted (built 2026-10-15)
date: 2026-10-15
amends: "[[ADR-199 Clinic Plays OpenPeon Sound Packs]] (the master switch is no longer only in the Sounds footer, and packs can be paused), [[ADR-123 Toolbar Choices Open In Popovers]] (a fourth split control)"
tags: [adr, sounds, toolbar, notifications]
---
# ADR-208: Sound packs pause from the toolbar

## Context
User (2026-10-15): *"The new sound feature is great, but I can see this being abnoxous if constantly on. Can we
add a global setting or topbar action that allows us to mute/disable/or pause the sound bits? (in this cause just
using normal notification sounds)"*

The global setting already existed: the *Sounds* switch in the Sounds screen's footer
([[ADR-199 Clinic Plays OpenPeon Sound Packs]]). Off, every moment falls back to ADR-097's notification sound,
which is the fallback the user asked for. But it sits on a screen opened to browse packs, so it is out of reach
when a pack gets tiring. It also has no way back on by itself, so turning packs off for a meeting means
remembering to turn them on again.

## Decision
- **A speaker in the toolbar**, a split control like caffeine ([[ADR-123 Toolbar Choices Open In Popovers]]),
  between Open In and the bell. It shows only while a pack is installed, since with none there is nothing to
  quiet. It lives in the shared `HStack` item with the other controls that come and go.
  - **The glyph says the state:** `speaker.wave.2` for on (the Sounds nav row's symbol), `speaker.zzz` for
    paused, `speaker.slash` for off.
  - **A click** turns packs off when they speak. When they are off or paused, it turns them back on.
  - **The chevron's popover** has a status header (*Sound packs on · Peon*, *Paused until 4:03 PM*, *Sound packs
    are off*), then *Resume Now* while paused, the three pauses with the time each would end, and *Turn Sound
    Packs Off/On*. Below that, a note that notifications keep their usual sound (or that a Focus is keeping Clinic
    quiet), and *Sound Settings…*.
- **Pauses are 30 minutes, 1 hour, or until morning.** Morning is the next 8:00, so a pause at 2 a.m. ends that
  same morning.
- **A pause is `SoundSettings.pausedUntil`,** stored with the rest, so it survives a relaunch. The router asks
  `isOn(_:at:)`, which reads the clock, so a pause can never outlast its date even if the timer is late. A timer
  in `SoundPackStore` clears the date when it passes, so the toolbar and footer change back by themselves.
  Pausing also switches packs on, because a pause promises they come back.
- **Off or paused means ADR-097's sound, not silence.** It is the same fallback as the switch being off. Quiet is
  the Focus filter's job ([[ADR-207 A Focus Filter Quiets Clinic's Sounds]]). Pausing or turning off also stops a
  line Clinic is playing, though not a preview the user started.
- **View ▸ Sound Packs** gives the same choices from the keyboard. Its toggle is rebindable as *Turn Sound Packs On
  or Off* and ships with no chord, like caffeine's.
- **The footer's switch** goes through the same store calls, so switching it on also ends a pause. While paused,
  the footer reads *Paused until …* with *Resume*.

## Consequences
- The composer's and the automation editor's voice pills still show while paused. The pause is temporary, and the
  pack they pick still applies afterwards.
- The status item's menu has no sound row. Add one if the toolbar proves not to be enough.

## Verification
- `make test`: 695 pass, 3 new (a pause holds the router until it ends, it survives the JSON round trip and old
  settings have none, morning is the next 8:00).
- Clinic Dev, driven by accessibility:
  - Pressing the speaker flipped `enabled` in `ClinicSoundPacks`, and its help text changed with it.
  - *View ▸ Sound Packs ▸ Pause for 30 Minutes* wrote `pausedUntil`, the speaker read *paused until 4:03 PM*, and
    the menu offered *Resume Sound Packs*.
  - With a pause seeded 25 s ahead and the app relaunched, the pause held. The popover (opened with
    `-ClinicToolbarPopoverOnLaunch sounds`) listed every row with its end time. At 25 s the log said
    `sound packs: pause ended` and the speaker read *on* again.
- **Not driven:** hearing the fallback sound during a pause. It is the switch-off path that existed before, and
  the router tests cover the pause. Manual check: pause from the toolbar, then let a background session finish a
  turn. You should hear the notification sound, not a pack line.
