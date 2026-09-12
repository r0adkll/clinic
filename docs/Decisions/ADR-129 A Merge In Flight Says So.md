---
status: accepted
date: 2026-09-11
tags: [adr, github, ui]
---
# ADR-129: A merge in flight says so

## Context
User (2026-09-11): *"On the PR panel when clicking merge on a PR there is no loading indication and
it seems like it did take until it updates and reflects the merge state. Can we better show the
processing time when using this action?"*

Pressing **Squash and merge** dismissed the confirmation and then changed nothing for several
seconds. `PRStore.perform` ran `gh pr merge` and, when that returned, re-read the pull request
([[ADR-127 The PR Panel Refreshes On Events Not On A Timer]]) — two subprocesses, measured at ~2–6
seconds against github.com. For that whole span the merge box looked exactly as it had before the
click: a live merge button, an enabled *Enable auto-merge* beside it, and the same green status
lines. The panel had the information — an action was running, and only the store knew — and spent it
on nothing.

Everything else in the panel that waits already says so. ⟳ spins for the reader's own press, the
Checks tab prints its own age and *Rechecking every 15s*, the Retry button on the unavailable screen
reads *Checking…*. The one gesture that changes something on GitHub was the one that stayed silent,
which is the wrong way round: a read that is a second late is invisible, a write that appears to have
been ignored gets pressed again.

## Decision
- **`PRStore` holds the action, not the view.** `perform` takes an `Acting` — which control was
  pressed (`merge`, `ready`, `autoMerge`) and the verb to show — and keeps it set across *both* the
  write and the read that follows. The merge is not done when `gh` returns; it is done when the panel
  can show the state it produced, and that whole span is what the reader is waiting through. A view
  `@State` flag could not span it, because the same store is what `PRPage` reads to redraw.
- **The control that was pressed becomes its own progress indicator.** The merge button keeps its
  place, its size and the service's green, and replaces its title with a white spinner and the
  method in the progressive — *Squashing…*, *Rebasing…*, *Merging…*. The method is named because the
  button was: "Squashing…" after "Squash and merge" is the same sentence, one tense on. Its chevron
  goes while it runs — there is nothing left to choose about a merge already on its way.
- **The rest of the footer goes quiet.** Every other action is disabled for the duration, and the
  one that is running shows its own verb (*Marking ready…*, *Enabling…*, *Disabling…*) with a spinner
  beside it. One write at a time per pull request: two of them would end in two reads of the same PR
  and show whichever landed last. `perform` enforces that, so the guard does not depend on the
  buttons being drawn disabled.
- **Failure keeps the existing path.** A `gh` error still lands in `errors[ref.id]` and prints under
  the page; the footer simply comes back. Nothing new is needed, because the spinner ending *is* the
  message that the attempt is over, and the box beneath it has either changed to *Merged into main*
  or not.

## Consequences
- `PRStore.perform` gains its `Acting` argument; all four merge-box call sites pass one. Nothing else
  in the app calls it.
- The wait itself is unchanged — this buys no speed, and says so honestly rather than pretending
  otherwise with an optimistic *Merged* the next read might contradict. GitHub's answer is the only
  thing that settles a merge ([[ADR-087 Pull Request Panel Is Status-First]]: enums reach the reader
  as sentences, and never a sentence Clinic guessed).
- Verified end to end in a smoke instance against a stubbed `gh` whose `pr merge` takes six seconds:
  the confirmation dismissed straight into *Squashing…* with *Enable auto-merge* dimmed, held for the
  whole call and the read after it, and gave way to *Merged into main*.
- **Not now**: the same treatment for writes started from outside the merge box (there are none yet),
  and a progress affordance on the footer chip or sidebar mark, which do not offer the action.
