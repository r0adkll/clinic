---
status: accepted
date: 2026-09-09
supersedes: the glyph half of ADR-040
tags: [adr, ui, sidebar, sessions]
---
# ADR-096: Session status indicators

## Context
User feedback 2026-09-09, after living with the sidebar: the state dots are hard to read as *state*.

[[ADR-040 Sidebar Ordering and Row Visuals]] specified "animated dot `working`, orange dot waiting
states, blue dot `unread`, hollow dot `exited`" in system semantic colours. The implementation drifted:
`StateGlyph` painted both `working` and `unread` in `Color.accentColor`, and the attached-session
`moon.zzz` too. That is the same colour as the sidebar selection fill, the active panel icons, the
tab chip's selected background and the drop indicator — so a status dot wore the app's chrome
colour and read as "selected", not as "running". It is also whatever the user set in System
Settings: on a red accent, `working` and `unread` are the same red as the selection behind them,
and the palette means something different on every machine.

The "animation" for `working` was a dot fading between 35 % and 100 % opacity. Pulsing is what an
*alert* does; it did not say "a process is running", and it was the same gesture ADR-040 wanted for
waiting states.

## Decision
- **Motion carries "running"; colour is spent only on the states that want the user.** `working` is
  an open arc (0.7 of a circle, round caps) turning once a second. `launching` is the same arc in
  `.secondary` — starting up is running, just not yet confirmed by `SessionStart`.
- **No status glyph is ever `Color.accentColor`.** The palette is fixed and semantic:
  | state | glyph | colour |
  |---|---|---|
  | `working` | spinning arc | inherits the row's label colour |
  | `launching` | spinning arc | `.secondary` |
  | `waitingForPermission`, `waitingForInput` | breathing dot | `.orange` |
  | `unread` | solid dot | `.blue` |
  | `idle` | solid dot | `.secondary` |
  | `exited` | hollow ring | `.secondary` |
- **The working arc takes no colour of its own**, so it inherits the row's label colour the way
  ADR-077's hover actions do. A fixed dark tint disappears into a selected row's accent fill; this
  is the only tint that is legible on every background the glyph lands on. Verified against a real
  `List(selection:)` in both focused (accent fill) and unfocused (grey fill) selection.
- **Waiting breathes, shallowly** — scale 0.85–1.0, opacity 0.7–1.0 over 1.1 s, slower than the
  1 s arc so the two motions never read as the same thing. A deeper breath was tried and rejected:
  at the bottom of its swing the dot was smaller and fainter than the idle dot beside it, so the
  one state that wants the user was the quietest thing on screen for half of every cycle.
- **Live state outranks the `unread` flag.** `StateGlyph` switched on `unread` first, so a session
  that had started working again still showed the stale "you haven't read this" dot. State first,
  then `unread` for the two resting states (`idle`, `exited`). `StatusItemController`'s menu glyphs
  follow the same precedence.
- **Reduce Motion is honoured**: the arc stops (its open ring still reads differently from every
  solid dot) and the waiting dot rests at full size — never at the bottom of a swing it can't leave.
- **The attached-session `moon.zzz` goes `.secondary`**, in the sidebar and the tab chip. It matches
  the background-agent moon it sits beside, and "attached, state unknown" is precisely not a state
  worth colour.

## Consequences
- Selection fills, active-control tints and the Chats icon keep the accent; status never does. New
  status affordances should reach for this table, not for `Color.accentColor`.
- Two `repeatForever` animations now run per visible live session. They are shape-only, and only
  for sessions in `working`/`launching`/waiting, so the resting sidebar animates nothing.
