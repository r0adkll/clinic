---
status: accepted (built 2026-10-06)
date: 2026-10-06
amends: "[[ADR-080 Diff Panel]] (several of its *Not now* items), [[ADR-101 Diff Panel Is List-Then-Detail]] (the file bar and the viewer), [[ADR-073 Rebindable Shortcuts]] (five actions)"
tags: [adr, diff, ui, panel, keyboard]
---
# ADR-188: The Diff panel is for reviewing

## Context
From the 2026-10-06 review. [[ADR-101 Diff Panel Is List-Then-Detail]] accepted that *"reading a whole scope
end to end takes clicks it did not before."* [[ADR-080 Diff Panel]] left word-level emphasis and a reviewed
mark under *Not now*, and [[ADR-100 Diff Body Is A Text View]] noted ⌘F was *"possible for free… not wired
up."* What was left was a viewer: one file, three lines of context, no way to the next change but the
scroll wheel, and nothing to say which files had been read. Some files showed nothing at all: a pure rename,
a mode change and an empty file drew an empty body, and a binary file said *0 bytes changed* whatever changed.

## Decision
- **Next and previous change**, from the file bar's chevrons and ⌃⌘↓ / ⌃⌘↑. A change is a run of changed
  lines (`DiffDocument.changeStarts`). It lands three lines below the top, and past the last change of a
  file it goes on into the next file, so one key reads a whole diff.
- **Next and previous file**, ⌥⌘↓ / ⌥⌘↑ and the file bar's menu, in the tree's order.
- **A viewed mark per file**, the file bar's tick and ⌃⌘V. Marking moves to the next file not yet viewed.
  The mark is kept against `UnifiedDiffFile.contentKey` (the diff's `index` line), so a file that changes
  again is unmarked on its own. Marked files lead their tree row with a tick, and the line under the header
  counts them. Marks live with the pane and are not stored.
- **The five actions are rebindable** ([[ADR-073 Rebindable Shortcuts]]), listed in the Panel menu, and work
  in the Diff panel and a pull request's Files tab. A pull request pane now holds its `DiffBrowser`
  (`PanelPane.changes`) so the commands can reach it.
- **The changed part of a changed line is emphasised.** A run of deletions followed directly by as many
  additions is read as line-for-line edits; each pair gives up its common prefix and suffix, and what is
  left takes the line's tint again, stronger. Pairs with too little in common beyond their indentation, and
  runs of unequal length, are left alone. It is not an intra-line diff: it finds the one edit in a line
  that has one.
- **Show Whole File**, in the file bar's menu: the selected file's diff with the whole file as context
  (`diff-tree -U100000` for that path). Offered where the diff has trees behind it, so not for a pull request.
- **⌘F finds in the body** while it has the keyboard, with AppKit's find bar; ⌘G is next match. The app's
  Edit menu has no Find item, so the text view takes the chords itself.
- **A file with no lines says why** (`UnifiedDiffFile.body`): binary and whether it was added, deleted or
  changed; renamed with contents unchanged, and from where; permissions changed, e.g. made executable; only
  line endings changed ([[ADR-184 The Diff Parser Reads What Git Writes]]); an empty file added or deleted.
- **Each scope says how much it holds.** The scope menu reads *Uncommitted · 10 files*, *Branch · 1 file*.
  An empty scope offers the scopes that are not empty as buttons. The counts are numstat by tree pair
  ([[ADR-183 The Diff Panel Has One Loader]]).
- **Open in Files** and Copy Path, in the file bar's menu.

## Consequences
- Verified in Clinic Dev through the accessibility API and screenshots: the chevrons, the viewed mark and
  its count, Show Whole File, each kind of file with no lines, the scope counts, and emphasis on a one-word
  edit. ⌘F was verified in a TextKit 2 harness, not in the app.
- The file bar drops its `+n −n` before its buttons when the column is narrow; the tree row says the same.
- Open in Files opens the file, not the line.
- Not now: a split view, image diffs, expanding context a few lines at a time, vim keys, marks that survive
  a relaunch.
