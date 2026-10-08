---
status: accepted (built 2026-10-06)
date: 2026-10-06
amends: "[[ADR-170 The Diff Panel Follows The Last Change]] (when *Latest changes* moves), [[ADR-101 Diff Panel Is List-Then-Detail]] (when the selection moves), [[ADR-080 Diff Panel]] (the header, and a scope's name)"
tags: [adr, diff, ui, panel]
---
# ADR-187: The Diff panel says what it compares, and holds still

## Context
User (2026-10-06): the panel *"doesn't feel very intuitive at all."* Three parts of that are about the
reader not knowing what they are looking at, or it changing while they look.

- **The header names a kind, not a comparison.** *Turn*, *Session*, *Working tree*, *Branch*. Session means
  "since this attach"; Branch means the newest commit on the default branch
  ([[ADR-170 The Diff Panel Follows The Last Change]]). Neither is on screen.
- ***Latest changes* swaps the diff under the reader.** ADR-170 has the panel move to a newer turn the
  moment it writes a file. A reader halfway down a file in the last turn is then in a different file of a
  different turn.
- **A file leaving the diff takes the selection with it.** `DiffBrowser.show` selected `files[0]` whenever
  the selected path was gone, so reverting or committing the file being read replaced it with another.

## Decision
- **A line under the header names both sides.** *Turn #2 · 12:06 PM → now, still running.*
  *feature 481a2f6 → working tree.* *Since this session attached at 1:10 PM → now.* *Where it left main
  (1a2b3c4) → d4e5f6a.* *Commit 1b9d7e6 against the commit before it.* It costs a row
  [[ADR-080 Diff Panel]] said the panel could not spare; it is one line of 11 pt text, and it is what the
  header was missing.
- **What the reader should know sits under it, one line each**, with at most one action: a newer turn held
  back (*Show*), a checkout that moved (*Show everything*,
  [[ADR-185 A Turn Knows Where The Checkout Stood]]), another session writing to the same checkout, a refresh
  that failed. The diff stays readable under all of them.
- ***Latest changes* waits for a reader who is engaged.** Engaged means they picked the file on screen or
  have scrolled into it (`DiffBrowser.isEngaged`). The panel then stays on the turn it is showing and offers
  the newer one: *Turn #2 has changes: ‹prompt›*, *Show*. A reader who has not touched the panel is moved as
  before. Coming back to the pane, and choosing *Latest changes*, both clear it.
- **Only a different diff may move the selection.** `DiffBrowser.show` takes `fresh`: the reader asked for
  another scope or turn, or the panel moved to another turn or commit. The same diff refreshing keeps the
  selected file. If that file has left the diff it stays on screen marked *no longer changed*, with no row
  selected in the tree, until the reader picks another.
- **The first file shown is the first row of the tree**, not the first path git sorted.
- ***Working tree* is named *Uncommitted*.** The scope's raw value is unchanged, so `-ClinicDiffScope
  workingTree` and stored selections still work.

## Consequences
- Verified in Clinic Dev: with a file of turn 1 picked, turn 2 writing a file left the panel on turn 1 with
  the offer; *Show* moved it.
- A reader who picked a file and walked away is still "engaged" when they look back at the same pane. The
  offer is one click. Hiding and showing the pane clears it.
- On the default branch, a commit landing is a different diff, so *Latest commit* moves to it.
