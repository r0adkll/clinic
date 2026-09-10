---
status: accepted
date: 2026-09-09
tags: [adr, editor, github, ui, panel]
---
# ADR-099: File tree rows are full-width controls, and the tree is a flat list

## Context
User (2026-09-09): *"The touch targets/responsiveness of items in the filetree of the 'files' tab is
not very good. tapping a row should expand or show the file contents. Please take a UI/UX pass at
this feature (and any other surfaces that use the same component)."*

Both file trees — the Files panel's repo tree ([[ADR-057 Editor Panel]], [[ADR-081 Files Panel Focus Modes]])
and the pull request panel's changed-file tree ([[ADR-091 Pull Request Panel Tabs and Files Tree]]) —
were `OutlineGroup`s inside a `List`, with each row a `Label` carrying `.contentShape(Rectangle())`
and `.onTapGesture`. Four separate faults came out of that one shape:

- **`contentShape` on a `Label` shapes the label, not the row.** `OutlineGroup` hands its content
  closure a view sized to its own content, so the hit area of `Models.swift` was about 110 pt of a
  195 pt column. Clicking anywhere right of the name did nothing — the complaint, exactly.
- **Directory rows had no tap handling at all.** The only way to open a folder was the 12 pt
  disclosure triangle in front of it.
- **Expansion lived inside the outline view, out of everyone's reach.** `EditorModel` rebuilds its
  tree on every debounced FSEvents burst, and nothing could expand the folders above a file opened
  from Quick Open or the agent's list, so opening a file left the tree pointing somewhere else.
- **A PR's tree arrived collapsed**, which is the worst default for a list that holds only the files
  the pull request touched: three folders and a click-down to reach the change you came to read.

Two performance faults sat alongside them. `PRFilesView.tree` rebuilt the node tree, ran ADR-091's
single-child fold and rebuilt the per-path stats dictionary *inside `body`*, and `matches(_:)`
re-ranked up to 300 paths through `FuzzyMatcher` two more times — all of it on every selection and
every keystroke. And `FileTreeNode.build` ran on the main actor over an index that may hold 50 000
entries, on every FSEvents burst, next to a terminal that is drawing.

## Decision

### The row is a `Button` whose label fills the row
One `FileTreeRowView` for every file list in the app: the repo tree, the PR tree, the PR filter
results, and Quick Open. It draws an optional chevron, a glyph, the name, an optional dimmed second
line and a trailing accessory, at `.frame(maxWidth: .infinity)` with the fill and the hit shape as
the same rectangle — what looks clickable is what is. 24 pt tall (AppKit's source-list height),
36 pt for the two-line variant, indented 13 pt per level with the chevron column reserved on leaves
so names line up.

A `Button`, not a gesture: its label hit-tests as one rectangle, it takes press feedback and the
accessibility role for free, and for a directory it makes the *row* the disclosure control rather
than the triangle in front of it. **A tap anywhere on a folder row opens or closes it; a tap
anywhere on a file row opens the file.** Hover gets its own fill, so a row says it is a control
before you click it.

### The tree is flattened before it is drawn
`FileTreeNode.rows(_:expanded:)` in ClinicCore produces a flat `[FileTreeRow]` — path, name, depth,
`isDirectory`, `isExpanded` — and the view is a `ForEach` over it. Flat rows are what let a row be a
full-width control at all, and they move expansion into the model, which fixes the other three
faults at once. `rows` descends only into open directories, so a collapsed 50 000-file repo costs one
pass over its top level and can be recomputed in `body` without care.

`FileTreeNode` and ADR-091's `compress` move from the app target into `ClinicCore/Editor/FileTree.swift`
alongside them, where they are Foundation-only and tested.

### Expansion belongs to the model, and opening a file reveals it
`EditorModel.expandedDirectories`, a `Set<String>` of relative paths. It survives the FSEvents
rebuild — a save must not collapse the folders you were reading — and `open` calls
`FileTreeNode.ancestors(of:)` on the new path and unions the result in, so a file opened from Quick
Open, the agent's list or a second pane expands its way onto the screen and a `ScrollViewReader`
scrolls it into view. A **Collapse All** button in the tree header undoes the accumulation.

`ancestors(of:)` is every path *prefix*, not the parent chain of the node graph. That is what makes
it work on a compressed tree: ADR-091's folded row keeps the deepest folded path as its identity, so
`.github/workflows` is named by the prefix set as surely as `.github` is.

### A pull request's tree arrives fully open
`PRFilesModel.sync` seeds `expanded` with `FileTreeNode.directories(nodes)`. The tree holds only the
touched paths, so "everything" is a dozen or two rows; the reader can close what they do not want.

### A `ScrollView`, not a `List`
macOS `List` inserts about 8 pt of its own spacing between rows, and `listRowSpacing` — the one
control for it — is marked `unavailable` on macOS. `listRowInsets(EdgeInsets())` does not touch it.
So a 24 pt row drew at a 32 pt pitch and a panel column lost a quarter of the files it could hold.
Measured side by side in a throwaway harness built from the real source: 64 px vs 48 px of pitch at
2×. `FileTreeScroll` is a `ScrollView` over a `LazyVStack`, which is still lazy, and section headings
become a plain `FileTreeSectionHeader` (not pinned — the alternative needs an opaque background that
has to match a container it does not own).

### A folded directory row truncates at the head
`api/src/commonMain/kotlin` is read from its tail; middle truncation ate the only segment that said
where you were (`Packages…ClinicCore`). Names without a `/` keep middle truncation, which preserves
the extension.

### The work the view was redoing moves into the model
`PRFilesModel` now owns `nodes`, `stats`, `expanded`, `filter` and the ranked `filtered` list,
recomputed when the diff arrives and when the filter text changes rather than on every `body`.
`EditorModel.reloadTree` builds off the main actor through a detached task.

### Not doing: keyboard navigation
Arrow-key traversal of the tree is the obvious next thing and is deliberately left out. It needs the
tree to hold keyboard focus, and this pane sits beside a live terminal surface — the same reason
ADR-081 refused to bind Escape to un-zoom. Worth its own decision, with the focus question settled
first rather than as a rider on a hit-testing fix.

## Consequences
- `FileGlyph` moves to `FileTreeRowView.swift` and gains rows for source files, archives and images.
- `PRFileTree`, `PRFileRow` and `PRFilterResultRow` are gone; only `PRFileStat` (the +/− or A/D
  badge) survives, as the shared row's trailing accessory.
- Quick Open's results are the same row and now scroll the arrow-key selection into view, which they
  never did.
- New smoke hook `-ClinicPRPaneOnLaunch conversation|checks|files` (ADR-038), so a run can open the
  pull request panel on its Files tab instead of driving a synthetic click into the tab strip.
- `FileTreeTests` covers build, fold, flatten, `directories` and `ancestors` — including that
  revealing a file makes it a visible row, which is the property the whole reveal path rests on.
- Verified on screen twice: the Files panel against this worktree (the tree revealed and scrolled to
  the file opened at launch), and the Files tab of Campfire #1069 (41 files, tree fully open on
  arrival). Then a guarded synthetic click 110 pt to the *right* of the `impl` folder's name
  collapsed it — the gesture that did nothing before this change.
