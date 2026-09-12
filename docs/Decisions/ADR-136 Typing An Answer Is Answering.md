---
status: accepted (built 2026-09-12)
date: 2026-09-12
amends: "[[ADR-132 The Grill Pane Is A Wizard]] (what the answer field is and what leaving it does)"
tags: [adr, ui, panel, grill, milestone-4]
---
# ADR-136: Typing an answer is answering

## Context
User (2026-09-12): *"its not obvious (or seems to even work) that typing in an answer to a question
'accepts' it or answers it. Also, we could improve the UI of this input box, maybe the placeholder
states the keyboard key to enter it, the skip text button seems duplicative, overall styling of the
input box."*

The first half is not a matter of taste — **the pane contradicted itself.** A typed answer lives in
`GrillPaneModel.drafts` until something commits it, and only `⇥` ever did: `⎋` set the mode back and
left the draft uncommitted, as did clicking any other control. Meanwhile:

- the progress strip, the answer badge and the header's *n of m* all read `round.answers`, so a
  question you had just written a paragraph into still showed as unanswered;
- the footer's *Send 4 of 6* and Send itself both read `withDrafts(round)`, so the same paragraph **was**
  counted and **was** sent.

So the reader typed an answer, watched the pane say nothing had been answered, and it was sent anyway.
"Seems not to even work" is the right description of a UI disagreeing with itself about whether
something happened.

The draft/commit split was introduced in [[ADR-131 The Grill Pane Answers A Round]] for a good reason —
writing every keystroke through the state file would be absurd — but that is an argument about
*persistence*, and it was wrongly allowed to become an argument about *display*.

## Decision

### A draft is an answer everywhere the reader can see
One round is computed for display, with every uncommitted draft folded in, and **everything that shows
state reads it**: the strip's pips, the badge, the header count, the review step, the footer. Typing
fills the pip as you type and the badge says *Your answer*, because that is what is true.

Persistence keeps its original rule: drafts stay in the model and reach `ClinicState` when the reader
leaves the field, so a paragraph still does not write the state file once per keystroke.

### Leaving the field commits it
`⎋` now **commits and stays**; `⇥` commits and moves on. There is no longer a way to leave the field
with the answer only half-real.

ADR-132 gave `⎋` "back to Navigate with the draft intact", meaning intact-but-uncommitted — a
distinction the pane had no way to show and no reason to hold. Cancelling what you typed is what
clearing the field is for.

### The field says which key opens it
Its placeholder names the key: **"Press e to write your own answer"**, or *…to add a note* when the
question already offers choices. A field whose placeholder is "Your answer…" tells a reader using the
keyboard nothing about how to get into it, and this pane is meant to be worked without the pointer.

The placeholder goes when the field has the keyboard — a caret and a prompt competing in the same box
is noise — and is replaced under the field by what the two exits do: *⇥ next · ⎋ done*.

### Skip moves out of the field's row
Skip sat immediately right of the text box, which read as a peer of typing and made the box look like it
had two ways to use it. It is not a peer: it is the third of the three answers a question takes —
accept, choose, skip — and the only one that had been glued to the text box.

It moves below the field, trailing, quiet, and carries its key (*Skip · s*), where it sits with the
other keyboard affordances rather than competing with the box.

### The box looks like a box you can type in
The border moves out of `NSScrollView` (`.lineBorder`, which cannot change with state) into SwiftUI, so
it is quiet when idle and **accent when the field has the keyboard** — the same signal the focused
question card and the current pip already use. It gains height (56 pt) and interior padding, because a
two-line box asking for a paragraph should not look like a one-line text field.

## Consequences
- `withDrafts` stops being a footer detail and becomes the pane's display model; the raw round is used
  only for identity and for writes.
- Answered-ness is now computed in one more place than it is stored, so the strip can show a question as
  answered a moment before `ClinicState` agrees. That is the right way round — the reader's typing is
  the truth and the file is catching up — but a future reader of the state file should not be surprised
  by it.
- `GrillAnswerField.Exit.cancel` keeps its name and stops meaning cancel; it now means *done, stay
  here*. The case is worth keeping distinct from `.next` because they differ in where they leave you.
- One fewer control beside the field, and one more line of text under it: net quieter, and the keys are
  now visible rather than only in the header's hint.

## Verification
Driven through the accessibility tree (Screen Recording is still declined for Claude Code).

- **Typing answers, visibly and immediately**: the pip read *not answered* before, **answered while the
  reader was still typing**, and the badge said *Your answer*.
- **`⎋` commits**: after it the question stayed answered and `ClinicState` held
  `Q1: {text: "my own answer"}` — the case that used to leave the pane insisting nothing was answered
  while Send sent it anyway.
- **The field names its key**: *Press e to write your own answer*, and while focused the line beneath
  reads *⇥ next · ⎋ done*.
- **Skip stands apart and carries its key**: the pane's buttons are now `Accept` and `Skip · s`, no
  longer a pair flanking the text box.
- Nothing else moved: arrows navigate, a digit picks, `s` skips, `⏎` reaches the review step, `⌘⏎` sent
  the round (`sent | 4 answers`), and the history list still walks and opens.
- **Clicking into the box works** (verified after the correction below, by locating the text area's frame
  through the accessibility tree and clicking its centre rather than guessing coordinates): the hint
  appeared, the typed text landed, and the pip went to *answered*.

455 ClinicCore tests pass and `make build` is clean. Smoke instance and its App Support removed.

**Appearance unverified**, as with ADR-133 onward: the new border, height and spacing have not been seen.

## Corrections
**The new border made the box untypeable.** Moving it out of `NSScrollView` and into a SwiftUI
`.overlay` put a hit-testing shape *above* the `NSViewRepresentable`, so every click into the box landed
on the border and the `NSTextView` never became first responder. The reader could type only by pressing
`e`; clicking did nothing at all. The placeholder overlay three lines below it carries
`.allowsHitTesting(false)` and the border did not.

It survived verification because every check in this ADR reached the field with `e` — the keyboard path
was the thing being tested, and the pointer path was never tried. A pane meant to be worked from the
keyboard still has to answer the mouse, and "I verified it" means the way a reader would do it, not the
way the test was convenient to write.

Restructuring `QuestionStep` deleted `ReviewStep`, `HistoryList`, `GrillAnswerRow` and `ReadOnlyBanner`
along with the code it meant to replace — a cut taken by position between two markers rather than by
the boundaries of what it was replacing. The build caught it immediately and they were restored intact,
but the file is untracked, so there was no history to restore *from*: it survived on being rewritten by
hand. Editing by span in a file git has never seen is a way to lose work that leaves no trace.
