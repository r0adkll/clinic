---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-056 Session MCP Tools]] (the attachments panel's UI only)"
tags: [adr, ui, panel, images, mcp]
---
# ADR-106: The Images panel is a viewer, not a contact sheet

## Context
User (2026-09-10): *"The image/attachments side panel needs some UX help. When viewing images its
impossible to resize/zoom/or otherwise adjust the viewer making it difficult to inspect images"*

[[ADR-056 Session MCP Tools]] gave `show_image` a home in one sentence — *"a gallery and a
lightbox"* — and that is exactly what was built: a `LazyVGrid` of thumbnails capped at 160 pt, and a
`.sheet` holding one `Image` with `scaledToFit` and a Close button. Sixty-one lines, and every verb a
reader of an image wants was missing:

- **No zoom.** `scaledToFit` is the only scale there is, so a 3600 × 2338 screenshot arrives at 16%
  of its size and stays there. A screenshot is the most common thing an agent shows, and its text is
  unreadable at 16%.
- **No pan**, because there is nothing to pan when the image can only ever fit.
- **Nothing to resize.** A SwiftUI `.sheet` takes the frame it is given; the reader cannot drag its
  corner, and the panel's own divider only makes the *grid* wider.
- **No 1:1.** Nothing in the panel could answer "what does this file actually contain", which is the
  question a reader is asking when they zoom in on a rendering.
- And it decoded every attachment with `NSImage(contentsOfFile:)` **inside the view body**, so every
  render of the pane re-read every file from disk.

Meanwhile the three file browsers next door had spent [[ADR-099 File Tree Rows Are Full-Width Controls]],
[[ADR-102 One Chrome For Every File Browser]] and [[ADR-103 File Browser Chrome Is Sized To Be Hit]]
converging on one shape — a list beside a detail view, one chrome, one row, one seam — and the Images
pane was the one pane in the panel that had none of it, and the only one with neither a zoom nor a
pop-out window ([[ADR-081 Files Panel Focus Modes]] gave files both).

## Decision
The Images pane becomes **list-then-detail around a real image viewer**, in the chrome the other
browsers already share. `AttachmentsPanel.swift` keeps its name and its `show_image` contract; the
grid and the sheet are gone.

### The layout is the one every browser uses
`PaneHeader`, `TreeToggleButton`, `TreeFilterField` and `TreeSplitHandle` from `PaneChrome.swift`,
assembled exactly as `DiffBrowserView` assembles them: a thumbnail list with the filter over it, one
image beside it, the toggle at the pane's top-left in **both** states, and a one-point seam dragged
in global coordinates that commits its width when the drag ends.

- `ImagePrefs` (`ClinicImagesShowList`, `ClinicImagesListWidth`, default 190) mirrors `EditorPrefs`:
  per-surface, for the reason [[ADR-091 Pull Request Panel Tabs and Files Tree]] gives — wanting one
  list open is not wanting them all open.
- **⌘⌃E is now "show / hide the front browser's list"** rather than the Files tree specifically.
  `TabStore.toggleBrowserList()` sends it to whichever browser is in front; the Panel menu's item
  renames itself, and the rebindable action keeps its identifier so nobody's `keybindings.json`
  breaks.
- The pane's minimum width is **400 with the list, 280 without**, and `SidePanel.renderKey` carries
  `ImagePrefs.showList` so the AppKit host re-opens the divider when that minimum moves under it
  (the mechanism ADR-081 built for the file tree).
- **Rows are their own view.** An image's identity is its thumbnail, which needs a row two and a half
  times the height of a file name, so `ImageRowView` is not `FileTreeRowView` — but it is the same
  full-width `Button` with the same fills and radius. It carries the caption (falling back to the
  file name), the pixel dimensions and the age.
- Filtering ranks captions *and* file names with the same `FuzzyMatcher` the other three browsers
  use.

### Zoom is measured in device pixels per image pixel
This is the decision the rest of the viewer follows from. **100% is one pixel of the file on one
pixel of the display** — the only level at which what you are inspecting is what the file holds, and
the level at which a Retina screenshot is exactly the size of the screen it was taken from. AppKit's
own `magnification` is therefore `zoom / backingScale`, and the document view is sized in **image
pixels** rather than in `NSImage.size` points, so two files with the same pixel dimensions cannot
disagree about what 100% means.

- **Fit never magnifies past 100%.** Blowing a 16 pt icon up to fill a 600 pt panel is not "fit", it
  is a decision the reader did not ask for.
- Fit is re-applied on every `layout()` while the viewer is fitting, so the image follows the panel's
  divider, the window's resize and the list opening — the complaint that started this.
- Verbs: `−` / `+` (√2 per press), a percentage that is also a menu (Fit, Actual Size, 25–800%),
  a fit/actual-size toggle, `+ - 0 1` from the keyboard, double-click to zoom in and back to fit,
  ⌘- or ⌥-scroll to zoom **about the pointer**, pinch, drag to pan with the hand cursor, arrows to
  pan, and ⌥↑/⌥↓ to walk the gallery.
- **Past 150% the image is drawn nearest-neighbour.** At that point the reader is looking *at*
  pixels — a screenshot's text, an icon's edge — and smoothing them smooths away the thing they
  zoomed in to see.

### An image window is a window
**Open in Window** (header button, row context menu, viewer context menu) opens a plain `NSWindow`
hosting the same `ImageDetailView`, one window per path, titled with the file name and subtitled with
its dimensions and size, `representedURL` set, opened at the image's own size and clamped to the
screen. AppKit rather than a `WindowGroup`, for [[ADR-081 Files Panel Focus Modes]]'s reason:
[[ADR-042 Launch Restoration]] opts the app out of state restoration.

This is what "resize the viewer" actually means. A window has a resize corner, a full-screen button
and a second display to go to; a modal sheet has none of those, which is why the sheet is not simply
being improved. Panel zoom (⌘⌥⇧J) already worked here and still does.

### Three corrections worth keeping
Each of these rendered *perfectly* and was wrong, which is why they are written down:

1. **`NSScrollView.minMagnification` defaults to 0.25.** Fit computed 32% for a 3600 pt screenshot,
   set the magnification, and AppKit silently clamped it to 0.25 — a 50% zoom on a Retina display —
   so the "fitted" image came up cropped on both axes while the readout honestly said 32%. Two
   fixes: set the limits from `minZoom`/`maxZoom`, and **read the magnification back** after writing
   it rather than trusting the value asked for.
2. **A view built against a current SDK does not clip its drawing to its own bounds.**
   `clipsToBounds` is now false by default, so the checkerboard under the image painted over the
   whole matte, and then the scroll view's matte fill painted over the pane's headers and its list —
   the panel came up as one dark rectangle. Both views set it explicitly.
3. **A SwiftUI overlay on an `NSViewRepresentable` is not clickable.** The zoom control was first a
   capsule floating over the image's bottom-trailing corner. It drew correctly and swallowed every
   click: the representable is a real `NSView` **subview** of the hosting view, and AppKit's
   `hitTest` hands the mouse to the topmost subview containing the point, so SwiftUI content drawn
   above it never sees the event. The control is now a real footer band under the image — which also
   means an image *window* gets it by construction.

### The image is a layer's contents, not something a view draws
Drawing the image in `draw(_:)` was the obvious first version and wrong twice over. A
3600 × 2338 pt document view inside SwiftUI's layer-backed hosting view allocates a backing store of
that size times the display scale — **about 134 MB for one screenshot** — and magnification then
scales that rasterisation rather than re-running `draw`, so every zoom past 100% came out blurred by
Core Animation's filter no matter what `imageInterpolation` was set to. The image is now a `CALayer`'s
`contents` with `layerContentsRedrawPolicy = .never`: the cost is the image's own bitmap once, at any
zoom, and `magnificationFilter` is the honest place to choose nearest-neighbour.

Everything that is *not* the image — the matte, the transparency checkerboard, the hairline outline —
is painted by the **scroll view**, in its own unmagnified coordinates. That view is the size of the
pane, so its backing store is too, and the checkerboard's squares stay a constant size on screen at
any zoom instead of becoming the picture at 800%.

### Reading files
`ImageFile` uses ImageIO, not `NSImage`: the pixel dimensions of a 20-megapixel PNG are a header
read, and a thumbnail for a 44 pt row is `CGImageSourceCreateThumbnailAtIndex` at 96 px rather than a
full decode plus a downscale. `ImageGallery` caches facts and thumbnails per path and keeps exactly
**one** full decode — the image on screen. A tiny image's thumbnail is drawn with no interpolation,
because a 4 × 4 file smoothed into a 48 pt box is a smear.

## Consequences
- `PanelPane` gains `images: ImageGallery?`, built in `makePane` beside the diff and editor models,
  so selection, filter, zoom and the decode caches survive hiding the panel and switching tabs.
- `show_image` still opens the pane, and now also **takes the selection**: the newest image is what
  the agent meant.
- The caption is on screen under the image rather than only in a tooltip, capped at two lines and set
  secondary — it is a label for the picture, not a paragraph above it.
- Verbs are one menu (`Open in Window`, `Reveal in Finder`, `Copy Image`, `Copy Path`, `Remove`)
  shared by the row, the viewer and the header's overflow. `Copy Image` writes the bitmap *and* the
  file URL, so the clipboard works in an editor and in Finder.
- Smoke hooks: `-ClinicOpenImagesOnLaunch <path>[,<path>…]` (records the images as attachments on the
  front session and opens the pane — otherwise this needs an agent to call `show_image`),
  `-ClinicHideImageList YES`, `-ClinicOpenImageWindowOnLaunch <path>`.
- A fourth browser now uses `PaneChrome`, which is the test ADR-102 set for it: its chrome came from
  using the shared pieces, not from copying a header.
