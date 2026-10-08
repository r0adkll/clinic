---
status: accepted (built 2026-10-06)
date: 2026-10-06
amends: "[[ADR-100 Diff Body Is A Text View]] (how the body updates), [[ADR-080 Diff Panel]] (what the highlighter parses)"
tags: [adr, diff, ui, panel, highlighting]
---
# ADR-186: The diff body changes in place

## Context
From the 2026-10-06 review. [[ADR-100 Diff Body Is A Text View]] rebuilt the whole document on any change
and ended every rebuild with *"A new file starts at the top left"*. Two things that are not a new file went
through that path:

- **Highlighting arriving.** Colours land a moment after the text. The reader who had started scrolling was
  returned to line 1.
- **The file changing under the reader.** While a turn runs, every write to the file on screen rebuilt it
  and returned to line 1, and dropped its colours until the next pass landed.

[[ADR-080 Diff Panel]] also said *"each hunk is parsed as two snippets"* and named whole-file context as
*"the obvious later upgrade"*. The code joined every hunk of a file into one snippet per side, so a hunk
that opened inside a string or a comment, or closed a brace it never opened, mis-coloured the hunks after it.

## Decision
- **Colour is applied to the text that is there.** `DiffTextRenderer.recolour` edits attributes on the
  content storage's `textStorage` inside one editing transaction. No glyph moves, so layout and scroll
  position stand. Measured in a harness built like the coordinator: 8,000 lines recoloured in 11 ms, scroll
  offset unchanged, every line still at `n × lineHeight`, and the view still on TextKit 2.
- **Only a different file starts at the top.** `DiffTextSource.fileGeneration` moves when another file comes
  on screen. The same file with new contents keeps the line at the top of the viewport and the offset into
  it. The line is found again by its **old-side** line number (`DiffDocument.line(matching:of:)`): a diff
  refreshing under the reader keeps its base and moves its head, so old-side numbers stay put while new-side
  numbers shift with every line written above. An added line is found from the numbered line above it.
- **The same file keeps its colours until new ones land.** They are replaced wholesale when the pass
  returns, since row ids may have moved.
- **Each side is parsed whole where it can be read.** A diff between two trees
  ([[ADR-183 The Diff Panel Has One Loader]]) can produce each side's file (`SnapshotStore.text(of:in:)`,
  text up to 1 MB). The highlighter parses it once and gives each diff row the colours of the file line it
  shows, by line number. The old side is applied first and the new side over it, so a context line reads as
  it does in the file being read.
- **Otherwise each hunk is its own snippet**, per side, as ADR-080 said. A pull request's diff has no trees
  behind it and takes this path.

## Consequences
- Verified in Clinic Dev: scrolled to line 153 of a 413-line diff, two lines written above, the same line of
  code at the top at line 155. A comment that begins above a hunk is coloured as a comment inside it.
- Captures are sorted stably, so where two start at one place the later in query order is applied last.
- Assembling a snippet used `(text as NSString).length` per line, which is quadratic in a whole file. It
  keeps a running offset.
- Highlighting a file costs two `git cat-file` calls per side. Nothing is cached across selections.
