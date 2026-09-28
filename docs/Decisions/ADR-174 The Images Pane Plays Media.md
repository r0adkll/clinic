---
status: accepted
date: 2026-09-28
amends: "[[ADR-106 The Images Panel Is A Viewer]] (what the pane holds, its name), [[ADR-107 The Images Pane Has A Finder Keyboard]] (space and ← / → for anything that plays), [[ADR-056 Session MCP Tools]] (what `show_image` accepts)"
tags: [adr, ui, panel, images, video, mcp]
---
# ADR-174: The Images pane plays media

## Context
User (2026-09-28): *"We should expand the capabilities of the images tab to be more "media"
orientated. We need to support rendering gifs and video files"*

What the pane did with each of them before this:

- **A GIF was a still.** `NSImage` plus a `CALayer`'s `contents` ([[ADR-106 The Images Panel Is A Viewer]])
  gets the first frame and nothing else. The same was true of APNG, animated WebP and HEIC sequences.
- **`show_image` refused a video.** Its check was `NSImage(contentsOfFile:) != nil`, so an agent
  holding a screen recording (the natural output of a simulator or a UI test) was told the file was
  unreadable.

## Decision
The pane keeps its structure (list, detail view, window, Quick Look) and gains two kinds of file.
Every file is one of `MediaKind.still`, `.animated` or `.video`.

### An animation plays on the image canvas
Animated images go through the same zoom canvas as stills, so everything ADR-106 decided still
applies to them: zoom in device pixels, fit never above 100%, nearest-neighbour past 150%, the
checkerboard. `ImageAnimation` swaps each frame into the canvas layer's `contents`.

- **A file is animated only when its frames carry delays.** A HEIC can hold a burst or a depth map.
  `CGImageSourceGetCount > 1` alone would try to play those.
- **The player has its own clock.** It does not use `CGAnimateImageAtURLWithBlock`, which can start
  and stop but cannot pause on a frame, step one frame, or report which frame is showing. Those are
  what a reader inspecting a recorded interaction needs. The clock runs on deadlines, so a long clip
  does not drift. If it falls more than a frame behind (the Mac slept, the app was busy), it restarts
  from now instead of racing to catch up.
- **One frame is decoded at a time.** A 400-frame recording costs one frame of memory.
- **Delays follow the browsers' rule.** A delay of 10 ms or less plays at 100 ms, because a GIF
  written with "0" expects exactly that.
- **An animation plays as soon as it is shown.** It is silent, and a GIF held on its first frame is
  a still the reader would have to ask to see move. It pauses when its view leaves the window (pane
  hidden, tab switched, window closed) and resumes when the view comes back.
- The footer gains **play/pause** and a **frame counter** (`12 / 40`), which comes before the
  dimensions and length when the band gets narrow.
- A standalone layer cross-fades every change to `contents` over a quarter second, which blended each
  frame into the next. The canvas turns off that implicit action.

### A video plays in AVKit's player
`VideoPlayerView` is an `AVPlayerView` subclass with inline controls. It does not put a player
layer on the zoom canvas. AVKit already provides the scrubber with thumbnails, volume, speed, frame
stepping, full screen, picture in picture and pinch to zoom, and Clinic would draw none of them as
well.

- **A video does not autoplay.** It can have sound, and a video the agent shows should not start
  talking over the reader's work.
- The footer keeps only the facts under a video (`1920 × 1080 · 0:12 · 4 MB`), because the player has
  its own transport. The facts, and the row's thumbnail (a frame half a second in, because a screen
  recording often starts black), come from AVFoundation, which only answers asynchronously.
  `ImageGallery` caches them like image facts. Its one observed counter, `videosLoaded`, is read by
  the two accessors, so rows that asked while a video was loading ask again when it lands.
- The player stops with its view (`dismantleNSView`), so it never plays on unheard and unseen.
- A video window opens at the default size and then takes the video's size once its facts load,
  keeping its top-left corner in place. Windows are now backed by an `ImageGallery` of one, so
  they read through the same caches as the pane.

### Space plays, ⌘Y previews
ADR-107 gave the pane Finder's keyboard. For anything that plays, space and ← / → go to playback
instead, as they do in QuickTime and every other player on the Mac:

| Key | Still | Animation / video |
|---|---|---|
| Space | Quick Look | Play / pause |
| ← / → | Walk the gallery | Step a frame (pausing first) |
| ↑ / ↓ | Walk the gallery | Walk the gallery |
| ⌘Y, Return, ⌘C, ⌘⌫ | unchanged | unchanged |

Quick Look is still one chord away: ⌘Y, the header's eye button, and the menu, whose title reads
*Quick Look · ⌘Y* for a playing item instead of *· Space*. `VideoPlayerView.keyDown` handles ↑ / ↓,
Return and ⌘⌫ and passes everything else to AVKit. That keeps one keyboard for the pane whichever
kind of file is selected.

### Copy keeps what the file is
- A video copies its **file URL**.
- An animation copies its **bytes under its own type** plus its URL. `NSImage` would have flattened
  it to its first frame.
- A still copies as before.

### The tool keeps its name
`show_image` now accepts videos, identified by type (`UTType` conforming to `.movie`), because
AVFoundation can only say whether a file is playable asynchronously and the tool call has a
15-second budget. If a file cannot be played, the player says so in the pane. The tool's
description names GIF, APNG, WebP, MP4 and MOV and "screen recordings", so agents know to use it
for these.

It is **not renamed** `show_media`. Users' on/off toggles are keyed by tool name
([[ADR-056 Session MCP Tools]]), running sessions already hold the old tool list, and the
description is what an agent chooses by.

### It is called Media
The tab, menu item, rebindable action title, empty states and footer chip say **Media**. The
internal names stay (`PanelPane.Kind.attachments`, `toggleAttachments`, `quickLookImage`,
`ClinicImages*` defaults keys), so nobody's `keybindings.json` or preferences break.

## Consequences
- New: `VideoViewer.swift` (`VideoFile`, `VideoPlayerView`, `VideoCanvas`). `ImageAnimation`,
  `MediaKind` and the delay reader live in `ImageViewer.swift` beside the canvas they drive.
- `ImageZoomModel.keyView` replaces `ImageZoomView.focusDocument()`. Clicking a row hands the
  keyboard to whichever view is showing: the image canvas or the video player.
- A row whose file plays shows a badge on its thumbnail: ▶ and the length for a video, ∞ and the
  loop length for an animation.
- AVKit is now linked into the app target.
- Verified in a smoke instance on 2026-09-28 with generated GIF, APNG, PNG and MP4 files: badges and
  lengths in the list, a GIF advancing 7/20 → 16/20 between two screenshots, and a video with its
  facts in the footer. The file-reading code was also run verbatim against the same files. Not
  exercised: the keyboard (no safe way to type into the smoke window) and a video window's resize.
