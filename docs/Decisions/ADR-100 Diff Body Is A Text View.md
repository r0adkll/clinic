---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-080 Diff Panel]] (body rendering only)"
tags: [adr, git, diff, ui, panel, performance]
---
# ADR-100: The diff body is a text view, not a stack of row views

> **Amended by [[ADR-101 Diff Panel Is List-Then-Detail]] (same day).** The measurements and the text
> view stand. What went with the continuous scroll: the in-text file header lines and their
> disclosure markers, the click-to-collapse hit test, the floating "which file am I in" header, and
> the "Show more" footer. The body now renders one file and takes a source and nothing else.

## Context
User (2026-09-10): *"The Diff view still feels like its not scrolling smoothly. For comparison, when
viewing files in the files tab it feels good, but when the diffing is enabled the performance is not
good."*

*Still* is the operative word. [[ADR-080 Diff Panel]] already fixed one chug by flattening the diff
into one row per line so a single `LazyVStack` could virtualise down to the line — that fixed how
much got **built**, and it was the right fix for that fault. What remained is what each visible row
**costs every frame**, and that is a per-row constant no amount of virtualisation removes.

Measured in a throwaway harness built from the real `DiffScrollView` and a real 7,524-row patch: a
timer-driven scroll at a fixed rate, main-thread CPU per frame (release build, M-series, 120 Hz):

| shape | 40 pt/frame | 80 pt/frame | frames over 16.7 ms @ 80 pt |
|---|---|---|---|
| today's `LazyVStack` of rows | 10.6 ms | 19.4 ms | **637 / 900** |
| …selection only on the code `Text` | 5.7 ms | — | — |
| …no per-row text selection at all | 3.7 ms | — | — |
| one text view, tints + ruler gutter | **1.7 ms** | **2.0 ms** | 1 / 900 |

The shipping view, measured the same way after it was built: **2.2 ms at 40 pt/frame, 2.3 ms at
80 pt, 3.4 ms at 160 pt** — a flick five times faster than the fastest measured above — with one
frame over budget in 900 at every speed.

The dominant cost is `.textSelection(.enabled)`, at roughly **35 µs per selectable `Text`**. Every
row carried four of them — old number, new number, marker, code — so a viewport of ~55 rows paid
~7.7 ms a frame for the ability to select text that, because each row is its own `Text`, could never
span more than one line anyway. Moving the modifier to the environment changes nothing: the cost is
per selectable `Text`, not per modifier application. Pinned section headers cost about another
1 ms; `scrollTargetLayout`, the visibility callback and the horizontal axis are noise.

Two further facts decided the shape rather than merely the size of the fix:

- **The SwiftUI cost scales with scroll speed** (10.6 → 19.4 ms as the step doubles) because it is
  paid per row materialised. A text view's cost is flat (1.7 → 2.0 ms): it draws a viewport, not a
  view tree. Trimming the row could reach ~5 ms; it could not make a hard flick free.
- **The Files panel is already a text view.** The comparison in the complaint is exact:
  `CodeEditSourceEditor` ([[ADR-057 Editor Panel]]) is an `NSTextView`, which is why one pane feels
  right and the other does not.

## Decision
The diff **body** becomes one read-only `NSTextView` per rendered page. Everything else ADR-080
decided — turn snapshots, the four scopes, the header, the file rail, the line budget, incremental
cancellable highlighting, models passed by reference — stands unchanged.

### The document
`DiffDocument` (ClinicCore, Foundation only) is built from a `DiffPage` and is the single source of
geometry: the plain text, one line per rendered row, plus per-line metadata (file index, row id, old
and new line numbers, kind) and per-file line ranges. Being a value type over arrays it is testable
without AppKit, which is where the mapping rules are pinned down.

**Uniform line height is the enabling invariant.** Every line carries a paragraph style with
`minimum == maximum` line height, so line *n* is at `n × lineHeight`, and the whole geometry problem
— which lines are visible, which file the reader is in, where to scroll to reveal a path, which
lines to tint — is integer arithmetic. No layout query anywhere in the drawing path. This is the
same trick ADR-080 used for the content width (monospaced font, so width is `columns × advance`),
extended to the other axis.

### The view
- **Text = code only.** Line numbers and the `+`/`−` marker are drawn by an `NSRulerView` gutter, so
  a copy yields code you can paste, and the gutter no longer scrolls out of sight horizontally the
  way an in-row gutter did. The gutter draws **one batched attributed string per frame**, not one
  `NSString.draw` per number: per-number drawing costs 1.8 ms a frame, because each call builds its
  own layout.
- **The gutter is an overlay, and the text is inset past it.** AppKit does not inset the clip view
  for a ruler (measured on macOS 26, and an explicit `tile()` does not change it), so the ruler is
  simply drawn over the body's left edge. The text clears it through `textContainerInset` — the one
  offset TextKit applies to *drawing* as well as layout. A paragraph head indent is not: it lays the
  fragment out at the right x and then draws the run shifted left, underneath the gutter.
- **Full-width `+`/`−` tints** are drawn in `drawBackground(in:)` from the visible line range.
- **The text view never sizes itself.** `isVerticallyResizable`/`isHorizontallyResizable` are off and
  the frame is set arithmetically. Letting `NSTextView` size to fit forces a full-document layout on
  every rebuild — **222 ms** for 7,580 lines, against **14 ms** when it is off. Page build is then
  ~34 ms all told, in line with the ~26 ms ADR-080 measured for building rows.
- **TextKit 2**, and the `textStorage`/`layoutManager` bridges are never touched (touching either
  drops the view back to TextKit 1).
- **Syntax highlighting** keeps ADR-080's incremental, cancellable, off-main-actor pass. The
  highlighter now returns **token ranges** (`DiffToken`: an `NSRange` and a colour) instead of an
  `AttributedString` per row; ranges are applied to the storage per file inside one
  `beginEditing`/`endEditing`.

### What changes for the reader
- **Selection spans lines and files.** A drag now selects a range of the diff and copies it as text;
  previously selection stopped at each row. This is a gain, and it is why the text carries file
  header lines: a multi-file copy reads like a patch.
- **File headers are lines of the document.** Each carries a disclosure marker (`▾` / `▸`), a path
  and its counts, and a click on one toggles that file's collapse — the marker is the only thing
  that says so, which is why it is in the text rather than in a control. A floating header for the
  file the reader is currently inside stands in for ADR-080's pinned section headers: it appears
  once that file's own header line has scrolled off, and the next file's header pushes it up.
- **"Show more" becomes a footer bar** rather than a row at the end of the content: a text view
  holds text, not buttons, and a pinned footer is reachable without scrolling to the end.
- The pull request panel's Files tab ([[ADR-091 Pull Request Panel Tabs and Files Tree]]) renders its
  one selected file through the same view, so there is exactly one diff renderer in the app.

## Consequences
- `DiffScrollView`, `DiffRowView`, `DiffLineView` and the unused `DiffView` are deleted.
- A per-row context menu is no longer available; per-file actions live on the header bar.
- `⌘F` inside the diff is now possible for free (`NSTextView`'s find bar) — not wired up here.
- The line budget stays. It exists for highlighting cost, not row cost, and that is unchanged.
- The harness that produced the table lives in the session scratchpad, not the repo; the numbers
  that matter are recorded here and in `Memory/Log.md`.
