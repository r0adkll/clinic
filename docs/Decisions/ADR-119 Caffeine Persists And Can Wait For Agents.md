---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-075 Caffeine Mode]] (its *not persisted* rule and its *no automatic mode* consequence)"
tags: [adr, ui, power]
---
# ADR-119: Caffeine persists, and can wait for agents

## Context
User (2026-09-10): *"I'm not sure the caffeine mode is always working. Also could we add a mode where
it can be on if an agent is running, maybe with some indication for it too"*.

`pmset -g log` showed that the assertion does its job while Clinic holds it. No idle sleep was
logged during any span in which *Clinic caffeine mode* was held. What the log did show was the
assertion ending as `ClientDied` three times that evening, at 19:55, 21:13 and 22:34. Each one was a
Clinic relaunch: a rebuild, an update or a crash. ADR-075 made caffeine *off on every launch*, so
after each relaunch the Mac went back to sleeping on its idle timer. The toolbar showed the cup as
off, but nothing drew attention to the change. From the user's side, that looks like caffeine
"not always working".

Two limits come from macOS rather than from Clinic, and no assertion gets around them:
- Closing the lid sleeps the Mac (`Clamshell Sleep` in the same log). The only exception is a Mac on
  power with an external display attached.
- Sleep from the Apple menu, the power button or a critical battery always wins.

## Options
- **Two independent switches**: *Caffeine Mode* on/off, plus *Only While Agents Work*. This was the
  first build. With two checkmarks that meant different things, the user found it *"not very clear in
  the dropdown which one is selected"*.
- **Two mutually exclusive modes, Always On and Agent Based** (chosen, as the user asked). The menu
  shows a check only on the mode that is active, and no check while caffeine is off. A click on the
  cup still toggles caffeine: off, or back on in the last mode used.
- **A three-way picker including Off**. The user asked for only the two modes, and choosing the
  checked mode already turns caffeine off.

## Decision
- **Caffeine is off, Always On or Agent Based** (`CaffeineController.mode`, nil when off). Choosing a
  mode turns caffeine on in it. Choosing the checked mode turns it off. Turning off remembers the
  mode, so the cup's click and the rebindable shortcut (*Turn Caffeine On or Off*) bring it back.
- **Both halves persist** (`ClinicCaffeine` for on/off, `ClinicCaffeineWhileWorking` for the mode).
  A relaunch brings the assertion back. A smoke instance reads them but never writes them, because
  it shares `UserDefaults` with the live app.
- **Agent Based** holds `beginActivity(.idleSystemSleepDisabled)` only while at least one agent is
  working:
  - a tab whose state is `working` (its `UserPromptSubmit` has arrived and its `Stop` has not), or
  - a detached agent whose `claude agents` state is `working` and that has no `waitingFor`
    (`BackgroundAgent.isWorking`). `status: busy` does not count, because the CLI reports it for an
    agent stopped on a permission prompt.

  A session counts once, whether the evidence comes from its tab, its detached agent or both.
  Waiting for permission or input doesn't count: a paused agent loses nothing if the Mac sleeps.
  The assertion's name says which mode took it (`Clinic caffeine mode` or `Clinic caffeine mode:
  an agent is working`), so `pmset -g assertions` shows why the Mac is awake.
- **The indicator is the toolbar cup**:

  | State | Glyph |
  |---|---|
  | off | `cup.and.saucer`, template |
  | Always On | `cup.and.saucer.fill`, accent |
  | Agent Based, waiting for an agent | `cup.and.saucer`, accent |
  | Agent Based, an agent is working | `cup.and.heat.waves.fill`, accent |

  The cup is a `Menu` with a primary action. A click toggles caffeine. The chevron opens the two
  modes under a header that says what caffeine is doing: *Caffeine is off*, *Caffeine is keeping
  the Mac awake*, *Caffeine is waiting for an agent to work*, or *Caffeine is keeping the Mac awake:
  1 agent working*. The tooltip says the same.
- **The toolbar menu is rebuilt whenever its header would change** (`.id(statusLine)`). The toolbar
  builds a `Menu`'s items once per toolbar item and never refreshes them, even when their inputs
  change. After *Always On* was chosen from the menu, it reopened with the check and header still
  on *Agent Based*. A new identity makes a new toolbar item, and so a current menu. The cost is that
  a menu left open while an agent starts or stops closes.
- **The toolbar draws its own image.** A toolbar `Menu` renders its label as a template and drops
  `foregroundStyle`. That is why the first screenshot showed a grey cup, and it is the same trap as
  ADR-116's merge button. The glyph is therefore a non-template `NSImage` in palette
  `controlAccentColor`, like the Open In menu's app icon. Every state is drawn on one 24×18 pt canvas,
  because the steaming cup is 4 pt narrower than the plain one and the toolbar would otherwise shift
  whenever an agent started or stopped.
- The **menu bar item** shows the same header and two modes. **View ▸ Caffeine** adds *Turn Caffeine
  Off* / *Turn Caffeine On (mode)*, which carries the rebindable shortcut.

## Consequences
- A persisted *Always On* can keep a laptop awake for days if the user forgets it. The accent cup in
  every window's toolbar is the reminder, and *Agent Based* is the mode to use when that is a
  concern.
- The tab state is only as accurate as the hooks. Claude Code sends no `Stop` for a turn the user
  interrupts, so an interrupted tab reads `working` until its next hook event. That event is
  expected to be the `idle_prompt` notification, which moves the tab to `waitingForInput`; this was
  not verified after an interrupt. Until then the assertion stays held: caffeine can hold too
  long, but it doesn't release too early.
- Detached agents are seen through the ADR-061 poll: every 15 s while one runs, and every 60 s
  otherwise. A newly started detached agent can therefore wait up to a minute before caffeine takes
  hold.
