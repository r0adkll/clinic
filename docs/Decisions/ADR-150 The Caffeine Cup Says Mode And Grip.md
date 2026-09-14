---
status: accepted (built 2026-09-14)
date: 2026-09-14
supersedes: "[[ADR-119 Caffeine Persists And Can Wait For Agents]] (its indicator table and its mode names)"
tags: [adr, ui, power, milestone-4]
---
# ADR-150: The caffeine cup says mode and grip

## Context
User (2026-09-14): *"I do like the single glyph design for the menu bar caffeine indicator, but I don't
find its states and agent-only modes super intuitive."*

The same session had just established that caffeine inhibits idle **system** sleep only, and that the
display sleeping is deliberate ([[ADR-075 Caffeine Mode]], reaffirmed). That left the indicator itself.

[[ADR-119 Caffeine Persists And Can Wait For Agents]]'s table encoded **two independent facts** —
*which mode is set* and *whether the assertion is held right now* — on one axis, inconsistently:

| ADR-119 state | glyph | problem |
|---|---|---|
| off | `cup.and.saucer`, template | — |
| Always On | `cup.and.saucer.fill`, accent | — |
| Agent Based, waiting | `cup.and.saucer`, accent | **the same shape as off**, separated only by tint |
| Agent Based, working | `cup.and.heat.waves.fill`, accent | — |

- **Off and *Agent Based, waiting* were one glyph.** That is the state an agent-based day mostly sits
  in, and it looked like the state where caffeine does nothing.
- **`.fill` meant nothing consistent.** It carried "on" for Always On, while for Agent Based the steam
  carried "holding" and the fill came along for the ride.
- **The words named a mode, not a consequence.** *"Caffeine is waiting for an agent to work"* does not
  say the thing you want while looking at a lit cup and a Mac that just slept: that the Mac **can sleep
  right now**.
- ***Agent Based* is jargon**, and does not pair with *Always On*: one names a duration, the other a
  mechanism.

## Decision
- **Three channels, one question each.**
  - **Shape is the mode, even while caffeine is off.** `onlyWhileWorking` persists, so the cup always
    wears the shape of the mode it is in or will come back on in. Steam is *While Agents Work*; a plain
    cup is *Always*.
  - **Colour is on or off.** Accent on, template off.
  - **Fill and motion are right now.** A solid cup that beats means an agent is working and the
    assertion is held; a hollow cup means the mode is armed and nothing is working.

  | State | Glyph | Rendering |
  |---|---|---|
  | off, *Always* | `cup.and.saucer` | template |
  | off, *While Agents Work* | `cup.and.heat.waves` | template |
  | Always | `cup.and.saucer.fill` | accent |
  | While Agents Work, waiting | `cup.and.heat.waves` | accent |
  | While Agents Work, working | `cup.and.heat.waves.fill` | accent, pulsing |

- **Turning caffeine off must not change the cup's shape.** The first build of this ADR let shape mean
  the *live* mode, so off was always the plain cup: in *While Agents Work*, one click swapped a
  steaming cup for a plain one **and** changed its colour. User: *"The glyph switch is really throwing
  me."* Two channels moving on one click reads as the icon being replaced rather than as a state
  changing. Shape is now the mode's fixed identity, and the click moves colour alone.
- **Motion carries "working", not opacity.** That first build also used a 0.55 alpha to separate a
  waiting cup from a working one, because fill alone is weak on the steaming pair — the waves are most
  of the glyph and identical in both. A pulse separates them far better than a static dim: it is the
  one channel nothing else uses, it says *live* in a way no weight can, and it frees opacity to stay at
  full strength so a waiting cup no longer looks half-disabled. `CaffeineController.isPulsing` drives a
  repeating `easeInOut` between 1 and 0.4 over 0.9 s, the shape of Apple's own `.pulse` symbol effect
  (which cannot be used here: `glyph` draws the symbol into a plain canvas, so the image is no longer a
  symbol image).
- **The modes are renamed *Always* and *While Agents Work*.** Both finish the sentence "keep the Mac
  awake…", so the rows read as two answers to one question. `Mode.phrase` carries the same names into
  running text (*"Click to turn it on while agents work"*).
- **Every menu teaches the glyph.** Each mode's row wears the cup the toolbar shows in that mode —
  filled, since a row names a mode rather than reporting a grip — in the toolbar popover
  ([[ADR-123 Toolbar Choices Open In Popovers]]) and in the status item's NSMenu
  ([[ADR-067 Menu Bar Status Item]]).
- **The words say the consequence.** The status line for a waiting *While Agents Work* is *"Caffeine is
  waiting — the Mac can sleep"*. It is kept short enough to stay on one line at the popover's 300 pt,
  because the status item draws the same string in an NSMenu section header, which truncates rather
  than wraps; what it waits for is the checked row directly beneath it. The tooltip has room to spell
  it out in full.
- **The popover carries a note**: *"The display sleeps on its own schedule either way."* The question
  that opened this session now gets answered where it is asked, rather than in an ADR.

## Verification
- All four symbols exist on this Mac and fit the fixed 24×18 pt canvas at 15 pt (`cup.and.saucer`
  24×17, `cup.and.heat.waves` 20×18), so ADR-119's reason for the canvas still holds — and within
  *While Agents Work* every glyph is 20 pt wide, so nothing that mode does moves the toolbar.
- **A new smoke key, `-ClinicCaffeineFakeWorking <n>`**, stands in for the agents a smoke instance
  cannot start, and is ignored outside one (`ClinicPaths.isSmokeInstance`, ADR-038: UserDefaults is
  shared with the live app, which must never hold the assertion on a test key). With it, **every state
  in the table was photographed in the real toolbar** rather than argued about — including the pulse,
  caught as a burst of frames 220 ms apart that shows the cup breathing between full and dim.
- The states read as intended side by side: off is a white steaming cup, waiting the same cup in
  accent at full strength, working the same cup filled and beating.

## Consequences
- **Off and waiting differ by colour alone**, which is the charge laid against ADR-119 above. It is a
  deliberate trade and a different situation: there, shape was *noise* — it changed between states
  within one mode while off and waiting shared a cup. Here shape is a stable per-mode identity and
  colour means on/off consistently in both modes, so the one question colour answers is always the same
  question. The user chose this after seeing both.
- **A pulsing toolbar item is motion in the periphery.** It runs only while an agent is actually
  working — never in *Always*, which would beat all day — and stops the moment the last agent stops.
- **Users who learned ADR-119's table relearn one state**: a waiting *While Agents Work* now steams.
- ADR-119's `.id(statusLine)` menu-rebuild workaround stays gone; a popover's content is ordinary
  SwiftUI (ADR-123), so the renamed rows and the new header refresh on their own.
