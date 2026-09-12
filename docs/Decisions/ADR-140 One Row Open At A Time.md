---
status: accepted (built 2026-09-12)
date: 2026-09-12
amends: "[[ADR-137 History Reads Like A Record]] (pinning, which it introduced)"
tags: [adr, ui, panel, grill, milestone-4]
---
# ADR-140: One row open at a time

## Context
User (2026-09-12): *"the collapsing logic on the round history panel for its questions is very buggy,
clicking to collapse some questions collapses different, and expanding will also collapse."*

Reproduced exactly, on a sent sample round:

| Gesture | What happened |
|---|---|
| (start, focus on Q1) | Q1 open |
| Click Q3's row | Q3 opens **and Q1 collapses** |
| Click Q3 again | **nothing visibly changes** |
| Click Q1's row | Q1 opens, Q3 closes |

[[ADR-137 History Reads Like A Record]] gave a row **two** sources of openness — transient, from focus
("the focused row expands as the reader arrows onto it, and collapses as they leave"), and sticky, from
pinning with `⏎`/`Space`:

```swift
func isHistoryExpanded(_ question: GrillQuestion, at index: Int) -> Bool {
    historyFocus == index || expandedHistory.contains(question.id)
}
```

For the keyboard that is coherent, because two different keys drive the two mechanisms: an arrow moves
focus, `⏎` pins. **The pointer has only one gesture**, and the row's action drove both at once —

```swift
model.historyFocus = index   // opens this row, closes whatever was open by focus
model.pinHistory(question)   // and toggles the pin
```

— so clicking a row collapses the previously focused one (symptom 1), and clicking the row you are
already on toggles a pin that focus is still holding open, which looks like nothing happening
(symptom 2). Clicking twice unpins it, so whether a row stays open after you leave depends on how many
times you happened to click it. There is no gesture that reliably closes a row.

## Decision

### Openness has one source: `historyOpenId`
At most one row is open, named by its question id. Focus and openness stop being separate ideas:

- **Moving the focus opens the newly focused row** and closes the one before it — arrow, `j`/`k`, or a
  click on a different row. ADR-137's "walking the list reads it" survives intact, because that is the
  behaviour it asked for.
- **`⏎`, `Space`, or clicking the row you are already on toggles it** open or closed. This is the
  gesture that was missing: there was previously no reliable way to close anything.

Every gesture now has one meaning, and the answer to "what will this click do?" is the same wherever
the reader is: *open that row, close the others; or close it if it was already the open one.*

### Pinning is dropped
It was the second source of openness and the cause of the collision. Two rows open at once is worth
very little here anyway: ADR-137 made the **collapsed** row carry the answer, so the thing a reader
would compare across rows is already visible on all of them without opening anything. What opening adds
is the question's body, and that is read one at a time.

## Consequences
- `expandedHistory: Set<String>` and `pinHistory` are replaced by `historyOpenId: String?`.
  `isHistoryExpanded` stops taking an index, which is what let focus and identity disagree.
- A reader who wants two bodies side by side no longer can. No one has asked for it, and the collapsed
  row carries the answer; if it is ever wanted, it should arrive as a deliberate "expand all", not as a
  second meaning for a click.
- The review step is untouched: it has no expansion, only a jump.
- **A history round now opens with nothing expanded.** Previously row 0 was open on arrival, because
  focus started at 0 and focus meant open. Now openness is only ever something the reader caused, which
  suits a list whose collapsed rows already carry the answers: scan first, open what you want.
- ADR-137's Decision stands except for pinning — its row design, header and "walking reads the list"
  are all unchanged.

## Verification
Reproduced before the change and re-checked after, on a sent sample round, pressing rows by name through
the accessibility tree (Screen Recording is still declined for Claude Code).

Before — the reported behaviour, exactly:

| Gesture | Open rows |
|---|---|
| start | `Q1` |
| click Q3 | `Q3` — Q1 collapsed |
| click Q3 again | `Q3` — nothing changed |
| click Q1 | `Q1` |

After:

| Gesture | Open rows |
|---|---|
| start | — |
| click Q3 | `Q3` |
| click Q3 again | — |
| click Q3 again | `Q3` |
| click Q1 | `Q1` |
| click Q4 | `Q4` |

Keyboard: `↓` walks and opens what it lands on, `↑` walks back and opens (`Q4` → `Q3`), `⏎` closes the
open row and opens it again, and `↓` on the last row stays put rather than wrapping ([[ADR-132 The Grill Pane Is A Wizard]]).

455 ClinicCore tests pass and `make build` is clean. Smoke instance and its App Support removed.
