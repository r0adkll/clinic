---
status: accepted
date: 2026-09-08
tags: [adr, editor, ui, panel, milestone-5]
---
# ADR-081: Focus modes for the Files panel — tree toggle, zoom, file windows

## Context
The Files pane ([[ADR-057 Editor Panel]]) is a fixed two-column layout inside the right-hand panel
([[ADR-079 Panel Tabs]]): a file tree that is always on screen beside a code view. The pane's minimum
width is 520 pt precisely because the tree takes 180–360 of it, so reading a file means reading it in
a column the tree has already taxed — and once you have picked the file, the tree is dead weight.

User (2026-09-08): *"The 'Files' panel could use some UX love. We should be able to show/hide the
file tree. Additionally, it might be nice to easily expand the selected file to full screen in the
app, and/or open it in a dedicated window."*

Three different needs, and they want three different answers, not one:
- **Hide the tree** — a per-pane layout preference, the cheapest and most common.
- **Full screen in the app** — a moment of "let me actually read this", ended as easily as it began.
- **A dedicated window** — the file leaves the session's flow entirely: kept open on a second display,
  beside a *different* session, alive after the panel tab is closed.

ADR-057 listed a pop-out window under "not now". This settles it; nothing in ADR-057 or ADR-079 is
reversed.

## Decision

### The tree is a toggle with a remembered width, and both are preferences
`EditorPrefs.showTree` — one observable object, not a flag per `EditorModel` — persisted in
`UserDefaults` under `ClinicEditorShowTree` and therefore shared live by every Files pane in every tab
and window: hiding the tree is a statement about how you read code,
not about one pane. The control is a `sidebar.left` button in the **code view's** header — the one
place that is on screen in both states, so the toggle can never hide itself. Menu: **Panel → Show /
Hide File Tree**, ⌘⌃E, enabled only while a Files pane is in front. The pane's minimum width is 500
with the tree and 360 without, so a hidden tree buys panel width back. That minimum is a **constant**;
see the second failure below for why it must never track the live tree width.

The default width is 180: the tree is a picker, not a reading surface, and the column it takes is
taken from the code.

The tree's width is remembered (`EditorPrefs.treeWidth`, `ClinicEditorTreeWidth`). The column is a
plain `.frame(width:)` beside a 9 pt `TreeResizeHandle`, and the handle's `DragGesture` measures in
**global** space. The live width lives in the pane's `@State` while dragging and is persisted once, on
`onEnded`. Clamping happens at draw time (160…480, and never leaving the code view under 300 pt), so a
panel too narrow for the chosen width borrows from the tree and gives it back when it widens rather
than overwriting what the user chose.

*Two corrections, both on 2026-09-08, both worth keeping:*
1. **A hand-rolled handle with a `.local` gesture is unusable.** `DragGesture` measures in local space
   by default and the handle moves as you drag it, so every frame's translation was taken against an
   origin that had just moved: the pointer and the column chased each other. Global space fixes it.
2. **The pane's minimum width must not track the tree.** With `minWidth = treeWidth + 330`, widening
   the tree moved the *panel's own* `NSSplitView` divider mid-drag, which changed the space the tree
   was being measured in. Layout answering a question that changes the question.
3. **`HSplitView` cannot carry a remembered width at all.** The intervening attempt — width in as
   `idealWidth`, out through a `GeometryReader` — looked clean and did nothing: the split view ignores
   `idealWidth` and hands its first child the *maximum* the frame allows, so every launch drew a 480 pt
   tree and stored 480 back. Measured, not eyeballed: the stored default came back as the clamp
   maximum every time. A remembered width needs a real width.

### Zoom is the panel's, not the editor's
"Full screen in the app" is implemented as **zoom on the panel**, not on the Files pane: the panel
fills the tab's content area and the agent surface is hidden behind it. A diff, a PR and a shell earn
this exactly as much as a file does, and the panel is already the thing that owns a width — zooming a
single pane would need a second, parallel mechanism that only the editor could use.

- `SidePanel.isZoomed`, one flag per session tab. Zooming shows the panel if it was hidden; hiding the
  panel un-zooms it, so the two controls can never leave the tab in a state with no way back.
- **Mechanically it is a re-parent, never a divider drag.** `TabContentView` takes the panel host out
  of the `NSSplitView` and pins it to its own bounds, hiding the split view whole. Driving the divider
  to zero instead would resize the agent surface to zero columns and reflow its scrollback —
  libghostty would have to give the content back at a width it never had. Hiding the split view leaves
  the surface at its real size, untouched, with only its occlusion flag flipped so it stops drawing.
  The surface itself is never re-parented ([[ADR-019 Window and Surface Lifetime]]); its ancestor moves.
- Controls: the zoom button sits next to the show/hide chevron in the session tab bar (the two
  controls that act on "the panel whatever it holds" belong together), **Panel → Zoom Panel**, and
  ⌘⌥⇧J. **No Escape binding**: a shell pane can be the thing zoomed, and swallowing Escape in front of
  a terminal is a worse bug than a second keystroke is an inconvenience.
- Not persisted, like panel visibility itself: a tab starts un-zoomed.

### A file window is a window, not a scene
**Open in Window** (header button, and the tree row's context menu) opens a plain `NSWindow` hosting
the same code view, with its own `EditorModel` rooted at the same repository.

- **AppKit, not a SwiftUI `WindowGroup`.** ADR-042 opts the app out of AppKit state restoration
  (`ApplePersistenceIgnoreState`), and a `WindowGroup(for:)` would try to restore file windows into a
  build whose scene shape may have changed — the exact failure ADR-072 already had to disarm. A window
  Clinic opens and owns needs no scene value, no environment injection, and closes when told to.
- **One window per path**, in a registry keyed by the absolute path: asking twice fronts the window you
  already have. Title = the file name, subtitle = its directory relative to the root,
  `representedURL` set so the proxy icon and its path menu work.
- **The window is single-file but not crippled**: ⌘S saves, ⌘⇧O quick-opens another file *into that
  window*, ⌘W closes it (with the standard save/discard/cancel sheet when the buffer is dirty).
- **Two buffers on one file is allowed and already handled.** Each model watches the file; a save in
  one is picked up by the other, silently when that buffer is clean and through ADR-057's
  "File changed on disk" prompt when it is not. Locking one editor out of a file the other holds would
  be a worse answer than the reconciliation that already exists.
- File windows are independent of the session: closing the Files pane, the tab, or its window leaves
  them open. They close with the app.

### Highlighting: fill the gaps the grammar package leaves
Three separate gaps, and only one of them is about markdown:

- **Detection is given the file's text.** `CodeLanguage.detectLanguageFrom` takes optional prefix and
  suffix buffers and uses them for shebangs and vim/emacs modelines; passing them costs nothing and
  makes an extensionless `#!/usr/bin/env python3` script highlight.
- **A small name/extension table** (`FileLanguage`) maps files the package does not know onto grammars
  it does have — `fish`/`zsh` → bash, `Podfile`/`gemspec` → ruby, `Package.resolved`/`jsonc` → json,
  `scss` → css. Only where the syntax genuinely is that language: a `.plist` stays plain text, because
  mapping it to something merely to get colour would be a lie about the file.
- **Markdown gets its own highlighter.** The tree-sitter grammar parses it correctly, but its captures
  (`text.title`, `text.literal`, `punctuation.special`, …) are not in CodeEditSourceEditor's
  `CaptureName`, so every one resolves to nil and the file renders as plain text. A highlight provider
  can only speak that same small vocabulary, so `MarkdownHighlighter` scans the document itself —
  `MarkdownSyntax` in ClinicCore, where it is Foundation-only and tested — and maps headings and bold
  to the keyword colour, code to strings, link text to types, destinations to attributes, quotes and
  front matter to comments, bullets to numbers. It is a scanner, not a CommonMark parser: it colours
  what a reader looks for and stops there. An edit invalidates the whole document, because one fence
  changes the meaning of everything below it.

### Shared code view, whose identity is the buffer
The code view, its header and the quick-open sheet move into `FileEditorView`, used by the panel's
right half and by the window. The tree, agent-files list and root header stay in `EditorPanel`.

With no file open the pane's `VStack` shrinks to its ideal height, and a `maxHeight: .infinity` frame
centres it — toolbar included — in the middle of the panel. The empty state carries the filling frame
instead, so the toolbar stays at the top in both states.

`SourceEditor` reads its text binding **only** when its view controller is made:
`updateNSViewController` pushes language, configuration and editor state, never text. So the code view
is wrapped in a `CodeView` identified by `EditorModel.loadGeneration`, a counter bumped on open,
external reload and revert — a load rebuilds the editor rather than trying to push text into one that
will not take it. This also drops the cursor, scroll position and undo stack that belonged to the file
that just went away, which is what should happen anyway. Without it the pane goes on showing whichever
file happened to be open when the view was built (found 2026-09-08, a latent ADR-057 bug: at launch the
first file loads because `open` runs before the view exists, so only the *second* file exposes it).

## Consequences
- `EditorModel` gains a `tree: Bool` init flag: a file window indexes for quick open but builds no
  tree, so a pop-out costs one watcher and no tree walk.
- `PanelContent` gains `zoomed`, and `SidePanel.renderKey` gains both that flag and the tree's, so the
  AppKit host is told to re-parent when zoom flips and to re-open the divider when the pane's minimum
  width changes under it.
- Zoom hides the agent surface while a session may be printing; its occlusion flag is set, so
  libghostty stops rendering rather than drawing into a hidden view.
- Two new rebindable actions (`toggleFileTree`, `zoomPanel`) join the Panel section of the shortcut
  editor ([[ADR-073 Rebindable Shortcuts]]).
- Smoke hooks: `-ClinicZoomPanelAfterLaunch <seconds>`, `-ClinicHideFileTree YES`,
  `-ClinicOpenFileWindowOnLaunch <path>`, `-ClinicOpenSecondFileAfterLaunch <path>` (the tree-click
  path: a file opened into a pane that is already on screen).
