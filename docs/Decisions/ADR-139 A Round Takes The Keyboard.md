---
status: accepted (built 2026-09-12)
date: 2026-09-12
supersedes: "[[ADR-131 The Grill Pane Answers A Round]] (the pane never takes focus on arrival), reaffirmed by [[ADR-132 The Grill Pane Is A Wizard]] and [[ADR-135 The Grill Pane Owns Its Keyboard]]"
tags: [adr, ui, panel, grill, keyboard, milestone-4]
---
# ADR-139: A round takes the keyboard

## Context
User (2026-09-12), after using it: *"One change to make from a previous decision is that the grill panel
should take focus when shown."*

[[ADR-131 The Grill Pane Answers A Round]] ruled the opposite, and it was put to the user as a question
at the time; they chose **"Never on arrival"**. The reasoning was that `ask_round` can land while the
reader is mid-sentence to the agent, and a pane that grabbed focus would eat the rest of that sentence —
following [[ADR-107 The Images Pane Has A Finder Keyboard]], where `show_image` can open the Images pane
while someone is typing and must not.

Two rounds of real use later, the cost of the rule is clearer than the cost it was avoiding. **Every
round begins with the reader reaching for the pointer or `⌘⇧K`** before they can answer anything, on a
pane whose whole argument is that a round you agree with is one keystroke per question. The friction is
paid every round; the sentence-eating was hypothetical.

The two cases are also less alike than ADR-131 assumed. `show_image` is the agent *showing* something —
the reader may well want to carry on typing. `ask_round` is the agent **stopping and waiting**: it ends
its turn immediately after, so there is no work in flight for a half-typed message to be part of.

## Decision
`ask_round` opens the Grill pane **and gives it the keyboard**, by the same path the reader's own
`⌘⇧K` takes — `TabStore.toggleGrill`, which shows the pane and sets `grillWantsKeyboard`. There is now
one way the pane is opened and one thing that happens when it is, which is simpler to hold in mind than
the split it replaces.

ADR-131's rule stands everywhere else: [[ADR-107 The Images Pane Has A Finder Keyboard]] is untouched,
`show_image` still opens the Images pane without taking focus, and no other tool moves the keyboard.

## Consequences
- A round arriving while the reader is typing into the agent's prompt will take the rest of that
  sentence — and, because the pane's Navigate keymap is live, the letters will be *acted on*: `s` skips
  a question, a digit picks a choice. That is the risk ADR-131 named, now accepted deliberately rather
  than by oversight. It is bounded by `ask_round` being the last thing an agent does in its turn.
- If it does bite, the narrower rule is to take the keyboard only when the agent surface does not hold
  it — which is checkable, since the pane's responder already asks the window who the first responder
  is ([[ADR-138 The Answer Box Was Never Given A Size]]).
- One fewer thing for the tool handler to decide: it calls the same opener the menu item does.

## Verification
Driven in a smoke instance, with the **terminal deliberately holding the keyboard first** — the case the
old rule existed to protect:

- Before: `focus: AXTextArea x=322 → TERMINAL`.
- A round posted through the real `ask_round` path (`clinic-hook` over the socket).
- After: `focus: AXGroup x=1127 → GRILL PANE`, and `↓` then `⏎` walked to Q2 and accepted it with no
  click and no chord in between.

And the carve-out still holds: with the terminal focused, `show_image` left the keyboard exactly where
it was (`AXTextArea x=322` before and after), so [[ADR-107 The Images Pane Has A Finder Keyboard]] is
untouched.

455 ClinicCore tests pass and `make build` is clean. Smoke instance and its App Support removed.
