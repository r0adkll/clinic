---
status: accepted (built 2026-09-12)
date: 2026-09-12
supersedes: "[[ADR-134 The Answer Field Owns The Keyboard]] (its diagnosis of why the arrow keys did not work, which was wrong)"
tags: [adr, ui, panel, grill, keyboard, appkit, milestone-4]
---
# ADR-135: The Grill pane owns its keyboard

## Context
[[ADR-134 The Answer Field Owns The Keyboard]] recorded six attempts to make the arrow keys navigate
the Grill pane, concluded that **SwiftUI will not deliver an arrow key to this pane**, and proposed an
AppKit responder as the fix. The user asked for that refactor.

The refactor was done, and it immediately proved the conclusion wrong.

With the pane's own `NSView` first responder installed and confirmed holding the keyboard — the
accessibility tree's focused element changed from `AXScrollArea` to the new view — **the arrows still
did nothing**. The cause was never SwiftUI:

```swift
guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
```

**An arrow key carries `.function` and `.numericPad` in its modifier flags.** A guard that demands no
modifiers at all therefore discards every arrow before anything looks at which key it was. That guard
had been at the top of this pane's keymap since [[ADR-131 The Grill Pane Answers A Round]], in
SwiftUI's `KeyPress.modifiers` form — which is why the arrow cases in the switch below it had never
fired — and it was then reproduced faithfully in the AppKit rewrite, which is why attempts four, five
and six failed too. Six experiments were run against the wrong hypothesis, and each one's failure was
read as confirmation.

The lesson is not about AppKit. It is that "the platform will not give me this event" is a conclusion
that needs the event proved absent, and it never was: no attempt logged what arrived. A single print in
`keyDown` would have ended it at the first try.

## Decision

### Arrows work, and the fix is one line
Modifier flags are filtered against what is *not* a modifier — `.shift`, `.function`, `.numericPad`,
`.capsLock` — rather than required to be empty. `↑`/`↓`/`←`/`→` navigate every one of the pane's three
keyboards (wizard, review step, history list), and the header advertises them.

### The pane keeps its own responder anyway
The refactor was not needed for the arrows. It is kept, because it fixes the *other* thing ADR-134
found — and that one was diagnosed correctly.

The pane's keyboard was SwiftUI `@FocusState` while the answer field's was AppKit's first responder,
and **neither system tells the other**. That split is what let the keymap fire inside the reader's
sentences: SwiftUI still believed the pane was focused while an `NSTextView` had the keyboard. ADR-134
papered over it with a mode guard, which works but leaves two sources of truth and a rule that has to be
remembered at every new call site.

Now there is one. `GrillKeyView` is the pane's first responder; `model.hasKeyboard` is set from
`becomeFirstResponder` and `resignFirstResponder`, so it is AppKit's answer rather than an inference;
and the header cannot advertise keys that would go to the terminal instead, because it is reading the
same truth AppKit is acting on. This is the shape [[ADR-107 The Images Pane Has A Finder Keyboard]]
settled for the Images pane, for the same underlying reason.

`GrillKeyView` draws nothing and returns nil from `hitTest`, so it takes no clicks; it is only ever
*made* first responder. ADR-134's fourth attempt put a view in the pane's background and never called
`makeFirstResponder`, which is why `keyDown` was never reached — `keyDown` walks up from the first
responder, and a view nobody has focused is not on that path.

### Handing the keyboard back is the pane's job
`⎋` in the answer field returns to Navigate, and the pane then reclaims first responder **from the text
view**. An early version of `updateNSView` refused to take focus whenever an `NSTextView` held it — a
guard meant to protect typing that fired on precisely the case it was there to serve, leaving `⎋` to
drop the keyboard on the floor. The protection belongs in the `wants` condition, which already requires
Navigate mode and is therefore false for as long as the reader is typing.

## Consequences
- ADR-134's Decision stands entirely except for its arrows section: the mode guard, the three pip
  states and the halo are unaffected. Only its explanation of the arrow keys is withdrawn.
- The pane's keymap now takes a `GrillKey` rather than a SwiftUI `KeyPress`, so it is one switch over
  named keys with no framework in it.
- `@FocusState` is gone from the pane. Anything that wants the keyboard sets `model.wantsKeyboard`;
  anything that wants to know who has it reads `model.hasKeyboard`.
- Two places now decide modifier filtering — `GrillKeyView` and the answer field's own responder — and
  they must agree that `.function` and `.numericPad` are not modifiers.
- The letter aliases (`j`, `k`, `e`, `s`, `1`–`9`) are unchanged and still work.

## Verification
Driven through the accessibility tree (Screen Recording is still declined for Claude Code), with each
pip carrying its state in an accessibility label.

- **All four arrows navigate**: from Q1, `↓` → Q2, `→` → Q3, `←` → Q2, `↑` → Q1.
- **Typing is untouched**: with the field focused, typing *"skip just 1 second"* — `s`, `j`, `k`, `1` —
  skipped nothing, navigated nowhere, picked nothing.
- **`⎋` hands the keyboard back**: the header returned to *↓↑ move · ⏎ accept · s skip* and `↓` moved
  again — the case the reclaim guard used to break.
- **`⇥` commits and advances**; `⏎` accepts; a digit picks; `s` skips.
- **Review step**: `↓` moved a row and `⏎` jumped back to it (`Q2 — answered — showing`).
- **`⌘⏎` still sends** from a question rather than the review step — a menu key equivalent, unaffected
  by the new responder: the round went to `sent` with four answers.
- **History list**: `↓` walked the rows and `⏎` opened the one it was on.

455 ClinicCore tests pass and `make build` is clean. Smoke instance and its App Support removed.

**Appearance remains unverified** — the three pip fills and the halo have still not been seen.
