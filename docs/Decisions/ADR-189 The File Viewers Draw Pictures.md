---
status: accepted (built 2026-10-08)
date: 2026-10-08
amends: "[[ADR-057 Editor Panel]] (*image preview* was under *Not now*), [[ADR-188 The Diff Panel Is For Reviewing]] (what a binary file's body shows), [[ADR-106 The Images Panel Is A Viewer]] and [[ADR-174 The Images Pane Plays Media]] (their viewer is now shared)"
tags: [adr, editor, diff, ui, panel, images]
---
# ADR-189: The file viewers draw pictures

## Context
User (2026-10-08): *"The various file viewers (Files tab, diff tab, etc) don't render media (such as png and
images as well as SVGs)"*

What each viewer did with a picture before this:

- **The Files pane refused it.** `EditorModel.open` read the file as UTF-8 and said *Not a UTF-8 text file*
  for a PNG. An SVG opened — it is text — as a wall of XML. [[ADR-057 Editor Panel]] had put *image
  preview* under *Not now*.
- **The Diff panel said what it was, not what changed.** [[ADR-188 The Diff Panel Is For Reviewing]] gave a
  binary file an honest state — *Changed. Its contents are not text, so there is nothing to compare line
  by line* — which is true and no help: a screenshot, an icon or a fixture image is exactly the kind of
  change a reader wants to *see*. An SVG's diff was its XML diff, from which nobody can tell what the icon
  now looks like.
- **A file window** is the Files pane's viewer in a window ([[ADR-081 Files Panel Focus Modes]]), so it had
  the same hole.

Meanwhile the Media pane next door had spent [[ADR-106 The Images Panel Is A Viewer]] and
[[ADR-174 The Images Pane Plays Media]] on a real viewer: a zoom canvas in device pixels, an animation
player, AVKit for video, a facts bar. It read only files an agent had sent it.

## Options
1. **Draw pictures in each viewer with its own `Image(nsImage:)`.** Quick, and the third viewer with no
   zoom, no 1:1, no pan — the shape ADR-106 replaced once already.
2. **Reuse the Media pane's `ImageDetailView` in both viewers.** Zoom, animation, video and the facts bar
   arrive built. The Diff panel's sides are blobs in trees rather than files on disk, which the viewer's
   players cannot read, so the blobs have to become files somewhere.
3. **Open pictures in the Media pane instead.** Keeps one viewer, but the Files pane's tree and the Diff
   panel's file list are where the reader is, and the Media pane holds what the agent sent, not what the
   repository has.

## Decision
Option 2. A file is a picture by its type — anything `UTType` says is an image (SVG among them), a PDF, or
a movie — decided once in `MediaFile`, the way `VideoFile.isVideo` already decides video.

### The Files pane shows the picture, and an SVG's source on request
- `EditorModel.open` no longer requires text. A picture is decoded off the main actor into `media`, and the
  viewer shows `ImageDetailView` over it: the zoom canvas for a still or an animation, AVKit's player for a
  video, the facts bar under either. The header names its type where a code file's language goes (*PNG
  image*, *SVG image*).
- A picture that is also text — an SVG — keeps its text. A **source toggle** in the header (`</>` / a
  photo glyph) switches to the code view, where it is edited and saved as before. `save` never writes a
  picture that has no text form.
- An external change reloads the picture as it reloads text.
- **Vector images are rasterised larger than they say.** An SVG's `NSImage` draws at its point size, so a
  24 pt icon would be 24 pixels and zooming in would show nothing but the zoom. `ImageFile.open` draws a
  vector into a bitmap whose long edge is at least 1024 pixels (never under 2× its points, never over
  4096), and records it as `ImageFacts.raster`. The facts bar still says `32 × 32`: the only size the file
  has. The canvas fits and zooms the raster.

### The Diff panel shows both sides
- `DiffContentSource` gains `data`, beside `text` and `whole`: a file's bytes on one side, through the new
  `GitRepository.data(of:in:scratch:)` (`cat-file blob`, no NUL check, a 64 MB limit) and
  `SnapshotStore.data`. `text` is now `data` plus the text checks.
- A binary file whose path is a picture shows `DiffMediaView`: **Before** and **After**, each in its own
  `ImageDetailView` with its own zoom, beside each other when the detail column is 640 pt or wider and one
  above the other when it is not. An added file shows one side and no heading; a deleted file the other.
  The chip in the file bar already says *new* or *deleted*.
- **Each side's blob is written to a cache file and shown from there.** The animation player and AVKit read
  from a path, not from bytes. `DiffMediaCache` writes a blob to
  `~/Library/Caches/<bundle id>/DiffMedia/<sha256>.<ext>` once, named by its contents so the same blob in
  two scopes is one file, and the Dev flavor's bundle id keeps its cache apart ([[ADR-176 Clinic Dev Is A
  Separate App]]). The files are small and the system may clear Caches; a missing one is rewritten.
- An SVG's diff is a **text** diff to git, so the viewer draws it when the path is a picture and offers the
  same source toggle as the Files pane, in the file bar beside the counts. Rendered is the default: what
  the icon looks like is the question; the XML is there for the one in ten times the answer is in it.
- The file bar hides `+0 −0` for a binary file, and the tree row's badge is **M** for a changed binary
  file, where it read `0` before.
- **A pull request's diff cannot do this.** It arrives as text from GitHub with no trees behind it
  (`canShowMedia` is `canShowWholeFile`), so its binary files keep ADR-188's words.

### What this does not do
- No image *comparison* (onion skin, swipe, difference blend). Two viewers side by side with independent
  zoom is what GitHub shows and what the reader asked for; a blend can come when someone wants it.
- No PDF page navigation: `NSImage` shows the first page, which is what a PDF in a repository usually is.
- Quick Look (space) and the Media pane's keyboard are not wired into these viewers; the Files pane's
  keyboard belongs to the code view and the tree.

## Consequences
- New: `MediaPreview.swift` — `MediaFile`, `MediaLoad`, `ImageFile.open` and the vector rasteriser,
  `MediaSourceToggle`, `MediaFileView`, `DiffMediaCache`, `DiffMediaView`.
- `EditorModel`: `media`, `showsMedia`, `showsMediaSource`, `hasMediaSource`, `loadMedia`. `FileEditorView`
  chooses between `MediaFileView` and `CodeView`.
- `DiffBrowser`: `showsMedia`, `hasMediaSource`, `showsMediaSource`, `data(of:side:)`. `DiffPanelModel`
  supplies `data`. `ImageFacts.raster`; `ImageDetailView` fits the raster when there is one.
- `ClinicCore`: `GitRepository.data`, `SnapshotStore.data`; `text` built on `data`. One new test reads a
  binary file on both sides of a working-tree pair.
- Verified in Clinic Dev on 2026-10-08 against a scratch repository (a 640 × 400 PNG changed, an SVG
  changed, a PNG added): the Files pane drawing the PNG with its facts and the SVG crisp at 1024 pixels
  with the source toggle in its header; the Diff panel showing Before and After for the PNG and the SVG,
  one side for the added PNG, and *M* on the changed binary's row. Not exercised: the source toggle's
  press (the same `Binding` flip in both places), a video on either side, the side-by-side layout in a
  wide panel, and a file window (it is `FileEditorView` with no tree).
