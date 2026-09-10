---
status: accepted
date: 2026-09-09
tags: [adr, github, ui, editor]
---
# ADR-092: Filtering and hiding the pull request file list

## Context
[[ADR-091 Pull Request Panel Tabs and Files Tree]] gave the Files tab a tree beside a single-file
viewer. Two gaps showed up straight away on a 19-file PR in a multi-module repo: there is no way to
jump to a file by name, and the tree permanently costs ~210 pt of a panel whose minimum is 380 — so
the diff, the thing you actually came to read, gets the narrower half.

User (2026-09-09): "add the ability to filter/search the files in the files tab of the PR view. Also
would be nice to be able to collapse/show the file tree for that same view."

## Decision
- **A filter field over the file list**, ranked with the existing `FuzzyMatcher` — the same matcher
  Quick Open uses (ADR-081), so `pbt` finds `PlaybackTimer.kt` in both places and there is one idea of
  what "search" means in this app rather than two.
- **Filtering swaps the tree for a flat ranked list**, name over dimmed parent directory. Searching
  and browsing are different acts: the hierarchy is what you want when you do not know the name, and
  noise the moment you are typing one. The list keeps each file's +/− count and A/D badge, so a hit is
  still readable as a change and not just a path.
- **A count — "13 of 19" — sits opposite the field** while a filter is active, because fuzzy matching
  is loose enough that the reader should be able to see how much it actually narrowed.
- **A toggle hides the list entirely**, giving the viewer the full pane. It lives in a toolbar row that
  is on screen in *both* states, so the toggle can never hide itself — the same rule the editor panel's
  header follows (ADR-081). With the list hidden the row shows the open file's path instead, so you
  still know what you are reading.
- **The filter field belongs to the list** and goes away with it. A search box that returns results
  into a hidden pane would be a puzzle.
- **Its own preference key, `ClinicPRShowTree`**, not the editor's `ClinicEditorShowTree`. They are
  different surfaces: wanting the repo tree open says nothing about wanting a PR's file list open.

## Consequences
- Escape clears a non-empty filter and is otherwise passed through, so it still closes the panel when
  the field is empty.
- No new global shortcut. ⌘⇧O already means Quick Open over the repo, and a second fuzzy-file
  shortcut that searched a different corpus would be worse than reaching for the field.
- Verified on screen against Campfire #1057: "timer" ranked `SleepTimerButton.kt` and
  `RunningTimerText.kt` first out of 13 of 19, clearing restored the tree, and hiding the list gave
  the diff the whole pane.
