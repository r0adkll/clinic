---
status: accepted (built 2026-10-10)
date: 2026-10-10
amends: "[[ADR-035 Action Callback Scope]] (what `open_url` does with a file)"
tags: [adr, terminal, editor, panel]
---
# ADR-192: Terminal file links open in the Files pane

## Context
User (2026-10-10): *"When click files in the claude code terminal UI it opens them by the system default,
it would be nice to open them in the Files tab in Clinic."*

Claude Code writes the paths it reads and edits as OSC 8 hyperlinks to `file:///absolute/path`. A
⌘-click reaches Clinic as libghostty's `open_url` action. `TabStore` handed every one to
`NSWorkspace.open`, so a Swift file opened Xcode and a Markdown plan opened whatever owns `.md`. That
took the reader out of Clinic to look at something the Files pane next to the session can already show
([[ADR-057 Editor Panel]], [[ADR-189 The File Viewers Draw Pictures]], [[ADR-191 The Files Pane Renders
Markdown]]).

## Decision
A ⌘-clicked link that names a file the Files pane can show opens in **that tab's** Files pane. The pane
is added and brought to the front if it was not, and the file opens at its line when the link names one.
Everything else goes to the system as before.

### What counts as a file link
`FileLink.resolve` (ClinicCore, tested) turns the action's URL into a path and an optional line:
- a `file:` URL, percent-decoded, with an optional `#L42`, `#42` or `#L42C7` anchor;
- a path Ghostty found in the text itself, which arrives relative to nothing. It is resolved against the
  tab's working directory, the shell's directory, which is where the text was printed;
- a trailing `:line` or `:line:column`, which compilers, grep and the CLI print, split off when the path
  with it does not exist and the path without it does;
- `README.md:12`, which `URL(string:)` parses as a URL whose *scheme* is `README.md`. A "scheme"
  containing a dot is taken as a path.

### What the pane takes
- A regular file the pane would open: a picture by its type, or text by its first 8 KB (no NUL, valid
  UTF-8 allowing for a character cut at the boundary) under the pane's 8 MB limit.
- Not a folder, a zip, a database or a compiled binary. Those still open in Finder or their own app. So
  do web addresses.

### Landing on the line
`CodeViewBridge` waits for the editor to be laid out in a window, places the cursor, and puts that line
a third of the way down the view. *Found 2026-10-10, twice:*
1. `TextViewController.viewDidAppear` did not reliably reach the coordinator inside SwiftUI, so the jump
   never ran. The bridge now polls for a few frames after `prepareCoordinator` instead.
2. CodeEditTextView's `scrollSelectionToVisible` measures the selection's drawn rect, which an empty
   selection does not have, so the cursor moved and the view did not. The bridge scrolls the clip view
   itself and redraws the editor's views, which keeps the gutter from drawing stale line numbers above
   the pane.

In Preview the page scrolls to the line's block instead. In Split both happen.

### A setting, and a way out
- **Settings → Sessions → Terminal → Open file links in the Files pane**, on by default
  (`ClinicOpenFileLinksInFiles`). Off, every link goes to the system as before.
- The file rows' context menu gains **Open with Default App**, so the old behaviour is one right-click
  away for the file you are looking at.

### Not in scope
- Run panes ([[ADR-122 Projects Have Run Configurations]]) still hand links to the system. A run's output
  is often a build log full of paths, and routing those is worth doing with the run's checkout as the
  base directory. That is its own change.
- The pane watches its repository root. A file opened from a link outside it shows, but does not reload
  when it changes on disk.

## Consequences
- `TabStore.openInFiles(_:from:)` sits in front of `NSWorkspace.open` for the agent and shell surfaces.
  `EditorModel.open(absolute:line:column:)` and `EditorModel.jump`.
- ClinicCore: `FileLink` and `FileLinkTests` (resolution, anchors, relative paths, `:line:column`, the
  dotted-scheme case, folders and web addresses refused).
- Smoke seam: `-ClinicOpenLinkAfterLaunch <url>` hands the launch tab a link as if ⌘-clicked.
- Verified in Clinic Dev on 2026-10-10 through that seam, with
  `file:///…/ADR-081%20Files%20Panel%20Focus%20Modes.md#L60`: the Files pane opened on the ADR in Split,
  the editor's cursor on line 60 with the line in view, and the preview following. Not exercised: a real
  ⌘-click on a cell (libghostty's delivery of `open_url` is unchanged), a relative path printed in a
  shell, and the setting turned off.
