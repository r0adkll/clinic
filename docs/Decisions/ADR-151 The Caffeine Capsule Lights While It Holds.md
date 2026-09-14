---
status: accepted (built 2026-09-14)
date: 2026-09-14
amends: "[[ADR-123 Toolbar Choices Open In Popovers]] (its one-capsule-per-control glass gains an optional wash)"
tags: [adr, ui, toolbar, power, milestone-4]
---
# ADR-151: The caffeine capsule lights while it holds

## Context
User (2026-09-14), straight after [[ADR-150 The Caffeine Cup Says Mode And Grip]] settled the glyph:
*"What options do we have for styling/coloring the pillbox in the menu bar?"*

Two constraints framed the answer before any option was drawn:
- **The capsule is shared.** `ownGlass()` wraps the Run pill, Open In, the device capsule and caffeine
  alike ([[ADR-123 Toolbar Choices Open In Popovers]]). Styling one means it stops matching its
  neighbours, on purpose.
- **Colour is already settled.** [[ADR-111 Nav Rows Wear Accent Tiles]] fixed Clinic's treatment as an
  accent glyph on an accent wash, never a per-item hue; a coffee-brown or amber pill is the direction
  that ADR rejected, under a new name.

The design question was therefore not *what colour* but *what the capsule should mean*, given the cup
already carries mode, on/off and holding. The user chose: **the wash tracks the assertion, not the
switch** — lit while the Mac is actually being held awake, plain while caffeine merely waits.

## What the SDK actually offers
`Glass` (SwiftUICore, macOS 26.2 SDK) is `.regular`, `.clear`, `.identity`, plus `.tint(Color?)` and
`.interactive(Bool)`. `glassEffect(_:in:)` takes only a glass and a shape — no `isEnabled:` — so a
conditional capsule means branching the modifier, not passing a flag.

## Options
All rendered in the real toolbar with `-ClinicCaffeineFakeWorking 1` (ADR-150) and compared at 4×:
- **`Glass.tint(.accentColor)`**, swept at 0.16 / 0.35 / 0.6 / 1.0. **Rejected.** Glass tint changes the
  capsule's *brightness*, not its hue: at 0.16 the capsule reads as **less** present than plain glass,
  and even at 1.0 it is a lighter grey pill rather than an accent one. Useful as a "selected" look,
  useless as a colour.
- **An accent ring** (`Capsule().strokeBorder`). **Rejected**: reads as a focus ring, and it encircles
  the chevron as well as the cup.
- **An accent overlay across the capsule.** **Rejected**: an overlay sits above the content, so it dulls
  every glyph it covers — the chevron went pink and the cup lost its edge.
- **An accent wash behind the content and above the glass** — `.background { Capsule().fill(wash) }`
  applied before `.glassEffect`. **Chosen.** The wash lands between the glass and the glyphs, so the
  capsule takes the colour while the cup and chevron stay crisp.

Swept again at 16 / 30 / 50 %: at 50 % the accent cup starts to lose contrast against the accent ground
— [[ADR-111 Nav Rows Wear Accent Tiles]]'s own problem, which it solves by turning the glyph white.

## Decision
- **The caffeine capsule washes `accentColor` at 16 % while `isHolding`**, and is plain glass otherwise.
  16 % is ADR-111's tile value, reused rather than re-invented; at that strength the accent cup needs no
  white treatment.
- **It tracks the assertion, not the switch.** *Always*, and *While Agents Work* with an agent working,
  light the capsule; waiting and off leave it plain. The pill answers the one question caffeine exists
  for — *is my Mac being held awake right now* — from the corner of the eye, and the cup says the rest.
- **The wash is always applied, at zero opacity when unlit**, with `.easeInOut(0.25)` on `isHolding`, so
  the capsule fades rather than snapping. The pulse (ADR-150) is driven by a different value and is
  unaffected.
- **`ownGlass(wash:)` carries it**, so any other control that earns one uses the same layering. Only
  caffeine passes one today.

## Consequences
- **The caffeine capsule deliberately stops matching its neighbours** while lit. That is the signal.
- **Two channels now say "holding"**: the cup fills and pulses, the capsule washes. Redundant by design —
  the capsule is what you catch without looking, the cup is what you read when you do.
- **One value covers both appearances.** 16 % was tuned against dark glass, and the concern was that
  light glass would want its own number. **User confirmed on screen (2026-09-14): it reads correctly in
  both**, so the wash stays a single constant rather than an appearance-dependent pair. Worth knowing
  for the next run: a smoke instance cannot be switched with `-AppleInterfaceStyle Light`, so checking
  an appearance means changing the system setting or asking.
- **Before macOS 26 nothing changes**: those systems draw no toolbar capsules at all, so there is
  nothing to wash.
