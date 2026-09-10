---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-080 Diff Panel]] (layout only)"
tags: [adr, git, diff, ui, panel]
---
# ADR-101: The Diff panel reads one file at a time, from a tree

## Context
User (2026-09-10): *"I'm now thinking that the continuous file scrolling of the diff view might not
be the best pattern. Instead we should use the same pattern as the diff/file viewer on PRs and add a
collapsable file tree to the left and have it view one file at a time."*

[[ADR-080 Diff Panel]] considered exactly this and chose the other branch: *"one continuous scroll
plus a file rail rather than list-then-detail"*, read like a PR review. The pull request panel then
went the other way a month later — [[ADR-091 Pull Request Panel Tabs and Files Tree]] says its Files
tab is *"deliberately the same shape as the editor panel rather than the diff panel's single
continuous scroll… a PR is read file by file, and a nested tree also shows the shape of the change,
which a flat rail of 19 paths does not."*

Both surfaces answer the same question — *what changed?* — and having them disagree about how to
present it was the real defect. The rail was the weakest part of ADR-080's layout: one row of
basename chips, no hierarchy, no counts wide enough to read, and a jump target that had to page the
scroll in before it could land. A tree carries the shape of a change; a rail carries its length.

The scrolling complaint that produced [[ADR-100 Diff Body Is A Text View]] is a separate axis and
that work stands: the body is still a text view, and it is still the only diff renderer in the app.
This decision is about what surrounds it.

## Decision
The Diff panel becomes **list-then-detail**, the same shape as the pull request panel's Files tab,
and the two share one implementation.

- **`DiffBrowser`** (app target) holds what both surfaces need: the changed files, the compressed
  tree ([[ADR-099 File Tree Rows Are Full-Width Controls]]), per-path stats, the expansion set, the
  ranked filter, the selected path, and the selected file's document and highlighting. **`DiffBrowserView`**
  draws the toolbar, the tree, the filter results and the viewer. The pull request panel's Files tab
  and the Diff panel are now both thin wrappers: the PR tab adds its loading and empty states, the
  Diff panel adds its scope header.
- **Tree state is per surface, not shared**: `ClinicDiffShowTree` / `ClinicDiffTreeWidth` beside the
  existing `ClinicPRShowTree` / `ClinicPRTreeWidth`, for the reason ADR-091 gives — a reader who
  wants one file list open does not necessarily want another's.
- **The file rail is removed**, and with it `DiffFileSummary`.
- **Paging is removed.** ADR-080's 20,000-row line budget, its "Show more" affordance,
  `DiffPage.fileLimit` and the row cache all existed because the panel rendered *every* file of a
  scope at once, and the budget was sized by highlighting cost. One file at a time bounds both by
  construction: building and highlighting a single file is a few milliseconds.
- **Per-file collapse is removed.** It was the escape hatch from a diff too large to scroll; the tree
  is a better one, and its disclosure is the collapse the user asked for.
- **Two columns, two headers, one divider.** The browser's chrome is not a row spanning the pane; it
  is a header per column — the filter over the list it filters, the file's name, status and counts
  over the diff it names — with the drag divider running the whole height between them. Stacked
  full-width rows cost a third row of chrome in a 380 pt panel and made the file bar read as though
  it belonged to the tree as well. The tree toggle lives in the list's header and moves to the file's
  when the list is hidden, so it can never hide itself (the rule ADR-081 set for the editor panel).
  A `new` / `deleted` / `renamed` chip sits beside the path: the tree's A/D badge has no room to say
  "renamed", and with the in-text file header gone that was nowhere.
- **The body loses everything that served the continuous scroll**: in-text file header lines and
  their disclosure markers, the click-to-collapse hit test, the floating "which file am I in" header,
  and the visible-file reporting. One file is on screen and the viewer's header names it — that
  question no longer needs answering twice. `DiffTextBody` takes a source and nothing else.

## Consequences
- ADR-080's rail, budget and collapse decisions are superseded; its snapshot machinery, scopes,
  header and read-only stance are untouched.
- A scope with many changed files now costs one file's rows, not 20,000 — the panel opens on the
  first file immediately, whatever the size of the diff.
- Reading a whole scope end to end takes clicks it did not before. That is the trade the tree buys,
  and it is the one the pull request panel already made.
- `-ClinicCollapseAllAfterLaunch` has nothing left to collapse; the diff panel's smoke hook becomes
  `-ClinicDiffSelectFile <path>`, which is what a reader's click now does.
- Selection survives a scope change when the path is still in the new diff, so switching Turn →
  Session → Working tree keeps you on the file you were reading.
