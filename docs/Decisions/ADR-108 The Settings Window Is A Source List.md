---
status: accepted
date: 2026-09-10
amends: "[[ADR-038 Preferences and Diagnostics]] (the window's shape and pane set), [[ADR-073 Rebindable Shortcuts]] (the shortcut editor's layout)"
tags: [adr, ui, preferences, settings, shortcuts]
---
# ADR-108: The settings window is a source list

## Context
User (2026-09-10): *"The settings panel is a little unwieldy to use since it can't be re-sized. Its
UI/UX leaves a lot to be desired as well."*

[[ADR-038 Preferences and Diagnostics]] deferred a preferences window to milestone 2 and never said
what one should look like, so it grew a `TabView` with `.frame(width: 560, height: 420)` and five
tabs. That single frame is the whole complaint:

| Pane | Content | Viewport |
|---|---|---|
| Shortcuts | 37 rows in five sections, ~2100 pt | 420 pt — **six rows** |
| General | 14 controls, ~700 pt | 420 pt |
| Notifications | ~300 pt | 420 pt |
| Diagnostics | ~250 pt | 420 pt |

Two panes scrolled and two wasted half the window, and nothing could be resized to fix either.

The contents had drifted too. "General" was a flat list of fourteen controls in the order they were
added — startup, window chrome, a Keychain connection, a default model, a worktree policy and a git
merge method with no headings between them — and its explanatory captions sat in the list as rows of
their own rather than hanging off the control they explained.

## Decision

### A source list in a window the reader owns
Five panes down the left, one pane on the right, in a window that resizes, zooms, miniaturises and
remembers its frame (`ClinicSettings`, 780 × 560 the first time, floor 660 × 430). This is the shape
System Settings itself has, and it is the one that survives the panes being different lengths:
Shortcuts is worth dragging tall, Advanced is not, and the reader decides which.

**It is a `Window` scene, not a `Settings` scene.** SwiftUI's settings scene builds a window with
neither zoom nor miniaturise — sensible for a fixed panel, wrong for one meant to be sized to the
pane you are in; its green button was dead even with `.resizable` in the style mask. A `Window` plus
`.windowResizability(.contentMinSize)` is an ordinary window with all three buttons live.
`CommandGroup(replacing: .appSettings)` rebuilds the **Settings…** item and ⌘, that the settings
scene would otherwise have provided, so nothing changes for the reader (verified against
`NSApp.mainMenu`: `Settings…[⌘,]`, second item of the app menu).

**The source list keeps its collapse toggle**, which an earlier draft removed on the theory that
hiding the list would strand a reader with no way back to the other panes. Two things say otherwise.
The toggle *follows* the collapse — it sits beside the traffic lights while the list is hidden, so the
way back is always in front of you. And removing it is what makes the window look wrong: see below.

### System Settings is the reference for the styling
User, on the first pass: *"can we update the styling to more closely match the built-in System
Settings"*. Screenshotted the real thing and matched it point by point rather than from memory:

- **Icon tiles in the source list** — a glyph on a 20 pt rounded square (radius 5, continuous). The
  tile is the cue that makes a source list read as a *settings* source list, and it is worth taking
  from System Settings. Its **colours are not**: a first pass copied System Settings' per-pane grey /
  blue / red / orange and the `.fill` symbols that go with them, and the user's reaction was the right
  one — *"I'm not sure I like the visual of those main setting icons… maybe we can stick more with the
  glyphs we use elsewhere and put them in a container/shape that takes on the accent colour"*. Those
  were the only filled symbols in the app and someone else's palette besides. So the tile carries
  **Clinic's own outline glyphs** (`gear`, `terminal`, `bell`, `keyboard`, `wrench.and.screwdriver`)
  on an **accent tint** — accent at 0.16 behind an accent glyph, which is exactly the on-state
  `PaneIconButton` already draws ([[ADR-103 File Browser Chrome Is Sized To Be Hit]]). One colour for
  all five: the glyph is the part that carries meaning, and a solid accent fill competes with every
  accent-coloured control in the pane beside it.
- **The pane's name goes in the title bar, and only there.** A draft followed System Settings, which
  names the pane *inside* the content, and hid the window title with `titleVisibility = .hidden` so
  the two would not collide. That was wrong twice over: the title bar then showed nothing at all
  (*"on first open 'General' or the default tab doesn't display"*), and once the sidebar became a
  unified one the content's own title sat one line under the bar that should have carried it, saying
  the same word twice. So `titleVisibility` is left alone, `.navigationTitle(pane.title)` names the
  window, and no pane draws a title of its own. It also buys back the 52 pt band those titles cost —
  Shortcuts shows nine rows where it showed eight.

  With no title band, **Shortcuts' filter moves into the toolbar**, beside the pane name. It is the
  only pane that needed chrome, and a band under the title bar holding one field would have been the
  second bar the change was meant to remove.
- **The source list is 215 pt** (System Settings' is 222).
- **A flat, full-height sidebar** — Clinic's own, not System Settings'. The user asked for *"the
  sidebar in the main part of the app where it flows up and behind the window controls"*, and the main
  window's is a flat column from the very top of the window with the traffic lights sitting on it.
  The settings window was instead getting macOS 26's floating sidebar: an inset rounded panel
  beginning *below* the title bar.

  **The cause was `.toolbar(removing: .sidebarToggle)`.** With no toolbar items left, the window has
  no toolbar, and a `NavigationSplitView` only unifies its sidebar with the title bar when one exists.
  Putting the toggle back is the whole fix — `titlebarAppearsTransparent`, `.windowStyle(.titleBar)`
  and wrapping the `List` in a `VStack` were each tried first and each changed nothing (all three were
  removed again; the last two are what the main window happens to do, which is what made them
  plausible).
- **One column for the whole pane.** A grouped `Form` caps and centres its own boxes past about
  760 pt, so every pane is pinned to a 760 pt column and keeps one measure at any window width,
  zoomed included, rather than letting the form decide.

That column has a second job: a `Section` footer is one long unwrapped line, and its ideal width
propagates. Before the column existed the window opened **1027 × 795** on a first run — SwiftUI sizing
the scene to the footers rather than to the `idealWidth` — and the deferred frame ran too early to
correct it. Bounding the column bounds the ideal, and the window opens at 780 × 560 again.

### Five panes, one word each, each one a subject
| Pane | Holds |
|---|---|
| **General** | *Startup* · *Automations* · *Window* · *Claude account* |
| **Sessions** | *New sessions* · *Archiving* · *Pull requests* · *Agent tools* |
| **Notifications** | the master switch and the sound rotation ([[ADR-097 Notification Sounds]]) |
| **Shortcuts** | [[ADR-073 Rebindable Shortcuts]]' editor |
| **Advanced** | *Diagnostics* · *Diff snapshots* (was "Diagnostics") |

The old "Session tools" tab — the MCP tool switches from [[ADR-056 Session MCP Tools]] — is a section
of **Sessions**, because that is what it is: what a session's agent may call. Folding it in is what
frees the slot for a Sessions pane at all, and what lets the git and model settings leave General.

Every caption is now a `Section` footer under the control it qualifies rather than a row in the list.
The one exception is *Agent tools*, whose description leads its section: it introduces seven rows of
bare tool names, and a footer would only reach the reader after all of them.

`LaunchAtLogin` and `AutomationWake` each keep their own refusal message, in the row beneath the
toggle that was refused. They shared one before, so a refusal from System Settings could appear under
the wrong switch.

### The shortcut editor answers "which key is this?"
Thirty-seven actions is more than any pane shows at once, so the pane gains the two things that makes
that bearable — a way to *find* one, and more of them on screen:

- A **filter** in the window's toolbar, matching an action's title, its section, or the chord it is
  bound to, so both `session` and `⌘N` find rows.

  It is the **system search field** (`.searchable`), not the `TreeFilterField` the file browsers use
  ([[ADR-103 File Browser Chrome Is Sized To Be Hit]]). A first pass reached for that one for
  consistency and got *"the search bar in Shortcuts is overlapping an other one"*: macOS 26 wraps a
  custom `ToolbarItem` in a Liquid Glass container of its own, so a field that paints its own capsule
  and border lands inside a second, offset one. The system field is the glass one — the way to get
  that material right is not to draw over it.

  What `TreeFilterField` carried and the system field has nowhere to put is the match count, so
  **"6 of 37" moves to the footer bar**: how much of the list you are looking at is the one thing a
  filtered list cannot tell you itself.
- The help text and **Reset All** are a footer bar pinned to the bottom of the pane. They used to be
  the last section of the scroll, which is to say reachable only by reading past every binding in the
  app. *Reset All* is disabled when nothing is overridden.
- The reset arrow moved to the **left** of the recorder so every chord box lines up on one edge, and
  still shows only for an overridden binding — that is the only place a reader can see that they
  changed something, which is worth more than the tidiness of hiding it until hover.

**The rows were double height for a reason worth writing down.** `LabeledContent` aligns its label
and its content on the **first text baseline**, and an `NSViewRepresentable` has no text baseline —
so SwiftUI took the recorder's *bottom edge* as its baseline, dropped the box below the label's line
and grew the row to fit both. `ShortcutRecorder` now answers `sizeThatFits` (the representable is
asked, not the view's `intrinsicContentSize`) and carries an explicit
`.alignmentGuide(.firstTextBaseline)`. Rows went 56 pt → 28 pt: **six visible became fourteen** at the
old size, and twenty-four in a zoomed window.

## Consequences
- The smoke argument `-ClinicPreferencesTab <name>` keeps working: `tools` resolves to Sessions and
  `diagnostics` to Advanced (`SettingsPane.named`). `-ClinicPreferencesOnLaunch` is unchanged.
- Two new `UserDefaults` keys appear the first time the window is opened and dragged — `NSWindow
  Frame ClinicSettings` and the split view's `NSSplitView Subview Frames settings, …`. Both are
  written into the *real* domain by a smoke instance ([[ADR-038 Preferences and Diagnostics]]'s
  amendment: `CLINIC_APP_SUPPORT` does not isolate `UserDefaults`), so a smoke run that opens
  Settings must delete them afterwards.
- The source list's width is a starting width, not a fixed one: AppKit lets the reader drag the seam
  and autosaves it, which is the behaviour every other split in Clinic has.
- `RootView` no longer holds `@Environment(\.openSettings)`; ⌘, and the menu item both post
  `.clinicOpenSettings`, which the front window turns into `openWindow(id: "settings")`.
- The window has no visible title, so it is the `Window` scene's name — "Clinic Settings" — that
  identifies it in the Window menu.
- `SettingsMetrics.column` / `.inset` and `SettingsPaneTitleBar` are the pane chrome; a pane that is
  only a `Form` gets both for free from `SettingsPaneBody`.

**Verified** in a smoke instance: all five panes at 780 × 560, against a screenshot of System
Settings taken alongside; the green button taking the window 780 × 560 → 1800 × 1130 (24 shortcut
rows visible, the column holding its measure and the title still on the boxes' left edge) and the
frame surviving a quit and relaunch;
`Settings…[⌘,]` present in the app menu; the filter, the pinned footer and the single-height rows.
`swift test --package-path Packages/ClinicCore` — 265 pass. The domain the smoke runs wrote to was
diffed against a snapshot taken beforehand and restored key for key.
