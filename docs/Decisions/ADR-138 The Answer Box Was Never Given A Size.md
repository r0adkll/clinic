---
status: accepted (built 2026-09-12) — one cause fixed, one still open
date: 2026-09-12
amends: "[[ADR-136 Typing An Answer Is Answering]] (how the field is built), [[ADR-135 The Grill Pane Owns Its Keyboard]] (when the pane claims the keyboard)"
tags: [adr, ui, panel, grill, appkit, bug, milestone-4]
---
# ADR-138: The answer box was never given a size

## Context
User (2026-09-12): *"I did find some weird input/focus bugs when trying to answer those questions."* —
and, in the round they were answering at the time, Q1 came back as the single character **`f`**.

That `f` is the whole bug in miniature. Reproduced: click the answer box, type `hello`, and what lands
is **`llo`** — the `h` goes nowhere, the **`e` is read as the keymap's "write your own answer"** and
opens the field part-way through the word, and the rest types. The reader's own letters are being read
as shortcuts because the click never put the keyboard in the box.

## What was found

### The text view was never given a size — this is fixed
`GrillAnswerField` built its `NSTextView` with a bare `GrillTextView()`, set it as `documentView`, and
set **no frame, no `isVerticallyResizable`, no `autoresizingMask`, and no text-container size**. A text
view built that way is effectively zero-sized inside its scroll view:

- **keys still work**, because a first responder receives them wherever it is and whatever its frame —
  which is why `e` opened the field and typing worked in every test that reached it that way;
- **the mouse does not**, because there is nothing under the pointer to hit;
- and typed text **did not render at all**. This was never noticed because every check until now went
  through the accessibility tree, which reports the value of a text view that is not drawing anything.

Fixed: the view is sized to its scroll view, tracks its width, is vertically resizable, and its text
container tracks the view. `isEditable` and `isSelectable` are now set outright rather than trusted to
a default. Typed text renders.

### The keyboard claim was not one-shot — this is fixed
[[ADR-135 The Grill Pane Owns Its Keyboard]] cleared `wantsKeyboard` only when the pane's responder
*gained* focus, so while it was true **every re-render re-claimed the keyboard** — including the
re-render caused by a click that had just put it somewhere else. It also called `makeFirstResponder`
from inside `updateNSView`, mutating observed state during a view update by way of
`becomeFirstResponder`.

The claim is now cleared when it is *issued*, performed on the next runloop turn, and re-checked
against what the reader has done since; `beginAnswering` cancels a pending claim outright.

### Clicking the box is still unreliable — this is **not** fixed
With both of the above corrected, clicking the box focuses it *sometimes*. What is known:

- Sibling controls in the same stack — *Accept*, the choice rows, *Next*, *Discard* — take clicks every
  time, so the pane is not inert.
- A `simultaneousGesture(TapGesture())` attached to the box **never fired**, so SwiftUI is not
  hit-testing that subtree either; this is not only an AppKit-side problem. That gesture was removed
  rather than shipped, since it does not work.
- It is not the pane's key-catcher: removing `GrillKeyView` entirely leaves the click just as dead.
- It is not the border or placeholder overlays; both carry `allowsHitTesting(false)`, added in
  [[ADR-136 Typing An Answer Is Answering]]'s correction.
- It is not `isEditable`, the scroll view's background, or the clip view.
- The one reproducible success came immediately after `⎋` from inside the field — so recent first
  responder history appears to matter.

Left open deliberately rather than guessed at again: six hypotheses were tried and discarded in one
sitting, and the honest state of it is "narrowed, not solved".

## Consequences
- The keyboard path is whole: `e` opens the field, typing renders, `⇥` commits and advances, `⎋`
  commits and stays, arrows navigate. **The pointer path is not**, so the pane is keyboard-first in
  practice as well as by design until this is finished.
- A stray character can still become an answer, because every exit from the field commits
  ([[ADR-136 Typing An Answer Is Answering]]) and there is no undo. That is how `f` was recorded. Worth
  its own decision once clicking works.
- Verifying through the accessibility tree hid a view that rendered nothing: AX reported a text area
  with the right frame and the right value while nothing was drawn and nothing could be clicked. **The
  tree says what the app believes; only pixels say what is there.**
