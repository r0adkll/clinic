---
status: accepted (built 2026-09-12); its arrows section superseded by [[ADR-135 The Grill Pane Owns Its Keyboard]]
date: 2026-09-12
amends: "[[ADR-132 The Grill Pane Is A Wizard]] (which keys navigate, and what the strip shows)"
tags: [adr, ui, panel, grill, keyboard, milestone-4]
---
# ADR-134: The answer field owns the keyboard

## Context
User (2026-09-12), using the wizard: *"The keyboard shortcuts interfere with direct text input. Can we
find better keyboard keys to use (like the arrow keys) and/or disable shortcuts when an input box has
focus (with Esc keep to exit input focus). Also, if a question was skipped should we make it visually
distinct in the bar? Also, if we navigate back to an answered question its hard to see in the timeline
bar which one is selected."*

Three faults, and the first is the serious one.

**The two modes were never actually separated.** [[ADR-132 The Grill Pane Is A Wizard]] asserted that
the answer field being an `NSTextView` was enough: the field takes AppKit's first responder, SwiftUI's
`@FocusState` therefore goes false, and the pane's `.onKeyPress` stops firing. **That is not what
happens.** AppKit's first responder and SwiftUI's focus are separate systems and neither tells the
other, so `navigating` stays true while the text view has the keyboard, and `navigate()` — which has no
mode check at all — keeps answering keys. Typing a sentence therefore fires the keymap inside it: `s`
skips the question being answered, a digit picks a choice, `j` and `k` jump to another question
mid-word. The mode existed in the model and was never consulted.

**A skipped question looked answered.** The strip's pip read `answers[id] != nil`, which is true for a
skip — correctly, since [[ADR-131 The Grill Pane Answers A Round]] makes skipping a decision — so "you
decide" and a real answer were the same solid accent disc.

**The current pip was invisible once answered.** Current was drawn as `strokeBorder(Color.accentColor)`
over a disc already filled `Color.accentColor`: an accent ring on an accent fill. Walking back to an
answered question left nothing on the strip saying where you were.

## Decision

### The field owns the keyboard while it has it
`navigate()` gains the guard it never had: **while `mode == .answering`, the pane's keymap is off** and
every key belongs to the field. The model is the authority rather than SwiftUI's focus state, because
the model learns the truth from `becomeFirstResponder` — the same event AppKit uses — instead of
inferring it.

`⎋` remains the way out and needs no change: `GrillTextView.cancelOperation` already returns the pane to
Navigate with the draft intact. It is now the *only* way out by keyboard, which is what makes the rule
learnable — one key, always the same, and the header says so while you are in the field.

### Arrows were attempted and do not work — the letters stay
> **Superseded by [[ADR-135 The Grill Pane Owns Its Keyboard]]. The conclusion below is wrong.**
> The arrow keys were arriving the whole time. This pane's keymap opened with
> `guard press.modifiers.subtracting(.shift).isEmpty`, and **an arrow carries `.function` and
> `.numericPad`** — so every arrow was discarded before anything read which key it was. Six experiments
> were run against the wrong hypothesis and each failure was taken as confirmation; none of them logged
> what actually arrived. Kept here rather than rewritten, because the mistake is the useful part.

This ADR set out to make `↑`/`↓`/`←`/`→` the documented navigation, on the grounds that an arrow cannot
collide with prose. They appeared not to be deliverable, across six attempts: `.onKeyPress(phases:)` on
the scroll view, the same on its container, `.onKeyPress(keys:)` naming all four, an `NSView` in
`background` implementing `keyDown`, a guarded local `NSEvent` monitor, and `.focusable(false)` on the
scroll view after the accessibility tree showed the focused element was an `AXScrollArea`.

So `j`/`k` remained the navigation and the header advertised them. ADR-135 fixed the guard, and the
arrows work.

### A pip has three states, and "current" sits outside them
The strip separates the two things it was conflating — **what happened to a question** and **where you
are** — by putting them in different parts of the pip:

| | Fill | Number |
|---|---|---|
| Unanswered | faint grey | grey |
| **Skipped** | solid grey | white |
| Answered | solid accent | white |

Skipped reads as *filled in, but not a decision with content*, which is what it is. It is a third look
rather than a variation on one, because at 18 pt a border is not a difference anyone notices.

**Current is a halo drawn outside the disc** — an accent ring set 3 pt clear of it — so it reads over
any of the three fills, including the accent one it used to disappear into. Position stops competing
with state for the same pixels.

Each pip also gains an accessibility label naming its question and state ("Q3 — skipped"), which
VoiceOver needs and which incidentally makes the strip checkable without a screenshot.

## Consequences
- The keymap is now off in more situations than before, so anything that leaves `mode` at `.answering`
  strands the reader until they press `⎋` or click a control. Every path that commits or abandons an
  answer already sets `.navigate`; a new one must.
- ADR-132's keyboard table stands, now explicitly Navigate-only. Its claim that an `NSTextView`
  separates the modes by itself is withdrawn. Its arrow bindings turned out to be right all along —
  see ADR-135.
- The strip grows to 30 pt to give the halo room, and pips space at 7 pt so two halos never touch.
- Three fills means the strip no longer answers "how much is left?" with one glance at colour alone —
  grey now means two different things depending on weight. The header's *n of m* remains the count.

## Verification
Driven through the accessibility tree — Screen Recording is still declined for Claude Code, so each
pip carries its state in its accessibility label, which is what made the strip checkable at all.

- **The fix**: with the field focused (`e`), typing *"skip just 1 second"* — containing `s`, `j`, `k`
  and `1` — skipped nothing, navigated nowhere and picked no choice. Before this, that sentence would
  have skipped the question, jumped twice and selected a choice.
- `⎋` returned the header to *j k move · ⏎ accept · s skip* and `j` moved again; `e`, typing, then `⇥`
  committed the answer and advanced.
- **Skipped is its own state**: `Q2 — skipped` where it used to read the same as a real answer.
- **Selection survives on an answered pip**: `Q1 — Accepting a recommendation — answered — showing`,
  which is the case that used to draw an accent ring on an accent fill and vanish.
- Arrows: measured not to fire, six ways — a wrong result, explained and fixed in ADR-135.

455 ClinicCore tests pass and `make build` is clean. Smoke instance and its App Support removed.

**Appearance still unverified** — the three fills and the halo are code changes I have not seen. The
states behind them are correct.
