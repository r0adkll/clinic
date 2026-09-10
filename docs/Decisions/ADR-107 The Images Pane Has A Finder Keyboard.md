---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-106 The Images Panel Is A Viewer]] (what the arrow keys do)"
amends: "[[ADR-081 Files Panel Focus Modes]] (who holds the keyboard, and what ⌘W closes)"
tags: [adr, ui, panel, images, keyboard, quicklook]
---
# ADR-107: The Images pane has a Finder keyboard

## Context
User (2026-09-10): *"Can we add some keyboard shortcuts that make this more powerful, like tapping
'space bar' when focused on an image opens a Preview style window (like finder). Enter maybe opens it
into a separate window. Cmd + C to quickly copy the image, etc"*

[[ADR-106 The Images Panel Is A Viewer]] gave the pane a viewer with keys of its own — `+ - 0 1`,
double-click, ⌥↑/⌥↓ — but every verb *about* an image was mouse-only: the pop-out lived behind a
header button, Copy and Remove behind a context menu, and there was no preview at all. The keys the
user named are the ones Finder has had for fifteen years, and a pane full of images that does not
answer them is a pane that has to be clicked through.

## Decision
The pane answers Finder's keyboard.

| Key | What it does |
|---|---|
| Space | Quick Look — the **system's** preview panel, over the pane's images |
| Return | Open in Window ([[ADR-106 The Images Panel Is A Viewer]]'s image window) |
| ⌘C | Copy the image (and its file URL) |
| ⌘⌫ | Remove it from the gallery |
| ↑ ↓ ← → | Walk the gallery |
| `+` `-` `0` `1` | Zoom in, out, fit, actual size (ADR-106) |
| ⌘Y | Quick Look, from the menu bar — the one path that needs no click first |

### Space is `QLPreviewPanel`, not a window Clinic draws
It *is* the thing the user asked for — the panel Finder opens on space — and it arrives with every
part that would otherwise be work: the zoom animation, ‹ › between items, the index sheet, "Open with
Preview", the share menu, Escape and a second space to dismiss. Clinic hands it a list of URLs and
the index to start on, so ‹ › walks the same gallery in the same order the list shows.

The panel is a system singleton that finds its controller by walking the responder chain, and the
controller is installed from **`AppDelegate.beginPreviewPanelControl`**: the app delegate is the last
link of that chain and therefore the only link that is present whichever half of the pane has
focus — a thumbnail row belongs to SwiftUI, the viewer is an `NSView`, and neither is a dependable
place to answer for the panel. `ImageQuickLook` holds the URLs and conforms `@preconcurrency`
(QuickLookUI's protocols are not main-actor annotated; the same hatch `MarkdownHighlighter` uses).

### The viewer is the pane's one keyboard
**`.onKeyPress` never delivers a command chord.** A focusable thumbnail list was built first and it
worked for ↑ ↓ space return — and silently dropped ⌘C and ⌘⌫ (measured: the clipboard still held its
sentinel string afterwards). SwiftUI routes command combinations through menu key equivalents, which a
pane-local key handler cannot see.

So there is one responder rather than two that each answer some of the keys: the viewer's canvas, an
`NSView`, whose `keyDown` takes the lot and whose `copy(_:)` makes **Edit ▸ Copy** light up and work
while the pane has the keyboard. Clicking a thumbnail row hands the keyboard to the viewer
(`ImageZoomModel.focusViewer()`), so a reader who clicked the picture and one who clicked its row have
the same keyboard.

**The arrow keys therefore change meaning**: they walk the gallery instead of nudging the image
about. ADR-106 gave them panning and put stepping on ⌥-arrows; panning already has three ways in — the
hand cursor, two-finger scroll, the scrollers — and stepping through the images had none, which is
what the pane is mostly for.

### Focus follows a click, and ⌘Y is the path that does not need one
The pane never *takes* the keyboard when it opens. `show_image` can open this pane while the user is
mid-sentence to the agent, and a pane that grabbed focus would eat the rest of the sentence — which is
also why [[ADR-079 Panel Tabs]] keeps the terminal focused for every non-terminal pane. Space is not
bound anywhere except inside the pane, and with the terminal focused it still types a space (verified).

That leaves ⌘⇧I → space needing a click in between, so **⌘Y** (Finder's own equivalent) is a
rebindable action in the Panel menu, enabled while an Images pane is in front. A command chord is safe
as a menu equivalent where space and return would not be, and the menu is also where a shortcut is
discoverable. For the same reason the context menus spell their keys in the item *titles*
("Quick Look · Space"): a bare space registered as a key equivalent would be a window-wide equivalent,
and the terminal is one keystroke away.

## Corrections
Three bugs this work walked into, two of them older than it:

1. **The agent surface was reclaiming the keyboard on every re-render.** `WindowState.updateNSView`
   asks the window to make the agent surface first responder whenever the terminal stack re-renders
   and the surface does not already hold it (ADR-081's rule, so focus never falls into a hidden
   surface). Adding or removing an attachment changes `sessions.state`, which re-renders the stack —
   so ⌘⌫ worked once and the *next* keystroke went to the session behind the panel. `TabContentView`
   gains `panelHoldsKeyboard`, and the surface no longer takes the keyboard out of the panel host,
   where the reader put it with a click. The same latent bug applied to the editor's code view and
   every browser's filter field.
2. **⌘W closed the session, not the window in front.** With an image window (or a file window,
   [[ADR-081 Files Panel Focus Modes]]) key, ⌘W fell through to the app's Close Tab command and put
   up *"Close this session? Claude Code is still running"* — a destructive prompt from a keystroke
   meant for the picture in front of the reader. `TabStore.closeFront` now closes the key window when
   it is one Clinic opened as an auxiliary, and only then falls back to closing the tab. This is the
   ⌘W behaviour ADR-081 already claimed for file windows.
3. **Image windows shared one autosaved frame**, so ADR-106's "opens at the image's own size" held for
   the first window and then quietly handed a 96 pt icon the frame a 3600 pt screenshot had left
   behind. Image windows cascade instead: their size is the image's, always.

## Consequences
- `ImageCommand` carries the verbs from wherever they were pressed to the pane, which is the only
  thing that can carry them out — Quick Look wants every image, Remove wants the store.
- An image window answers ⌘C and space too, because it hosts the same `ImageDetailView`.
- One new rebindable action (`quickLookImage`, ⌘Y) joins the Panel section of the shortcut editor
  ([[ADR-073 Rebindable Shortcuts]]).
- Removing the selected image re-asks for the keyboard on the next turn, so ⌘⌫ is repeatable.
- QuickLookUI is now linked into the app target.
