---
status: accepted (designed 2026-10-15; step 1 built 2026-10-15)
date: 2026-10-15
supersedes: "[[ADR-049 Tab Bar]] (the session tab bar), [[ADR-079 Panel Tabs]] (one panel beside the agent, footer quick actions, panels not persisted), [[ADR-059 Replay and Session Details]] (replay as its own tab)"
amends: "[[ADR-041 One Tab Per Session]] (a session is open in one window's workspace), [[ADR-042 Launch Restoration]] (a session's layout is restored when it is reopened), [[ADR-130 Shift-Click Closes A Tab]] (no session tab to ⇧-click), [[ADR-198 The Panel Holds Several Terminals]] (Files may hold several too), [[ADR-197 Only The Tab On Screen Takes The Keyboard]] (on screen = the selected session's front panes), [[ADR-120 The Empty Screen Is A Home]] (no New Shell card), [[ADR-036 Keyboard Shortcuts]] (⌘1–9 pick tabs)"
tags: [adr, ui, tabs, panel, sidebar, keyboard, persistence]
---
# ADR-212: A session is a workspace of tabs

## Context
User (2026-10-15): *"Currently, we tab all open sessions in the main view and then show X number of panels in a
per-session side panel. I would like to shift to a more per-session focus for the main app area instead of this
hybrid mix of all sessions. The TL;DR of it is when you select a session it shows, as its own tab, in the main
area. Then you could add any number of tabs that associate to the session into the main panel (terminals, files,
diff, etc). Then you can also open a right panel and add more tabs there. So more of a per-session generic
panel/tab setup rather then the more opinionated format we have now. The side bar takes care of holding and
displaying the status of other open sessions."*

The window had two strips. The session tab bar ([[ADR-049 Tab Bar]]) listed every open session and shell. Beside
each session's terminal was a panel of panes ([[ADR-079 Panel Tabs]], [[ADR-198 The Panel Holds Several Terminals]]).
A file or a second terminal could only ever sit in the narrow column, never where the agent was. The sidebar
already shows every open session's state, branch, context and activity as a card ([[ADR-156 Sessions Can Be Cards]]),
so the tab bar repeated it.

Three directions were mocked on a design canvas from the user's real projects and sessions
(https://claude.ai/artifact/8wdUwg5txLLLaMCd7nEeQM): **A**, a workspace strip in the old tab bar's place; **B**,
a session header over underlined tabs; **C**, two equal tab groups with a sidebar sorted by attention. Two Grill
rounds settled the rest. The canvas's *After round 1* artboard is the reference.

## Decision

### A window shows one session
- **The session tab bar goes.** The sidebar is the only list of sessions. An open session is shown in place under
  its project, as a card in Card mode or in Automatic for open sessions ([[ADR-156 Sessions Can Be Cards]]). There
  is no separate *Open* section and no attention-sorted sidebar.
- **Each open session is a workspace with two tab areas**: the main area, and a right panel that shows or hides.
  Both areas take any pane kind (terminal, files, diff, PR, media, Grill, run), and a tab moves between them from
  its own move button or its context menu. Terminals and Files may be open several times. Every other kind is
  one per session, and PRs are keyed by their ref, as before.
- **Claude is pinned first in the main area.** It cannot be moved or closed on its own. Closing it means closing
  the session.

### The header names the session
Direction B. The toolbar's leading side shows the project tile, the session title and a state pill. Under them,
one line reads project · branch · model ▾ · effort ▾ · context gauge. Clicking the project · branch part copies
the working directory, as the footer path did. Its trailing side keeps the existing toolbar controls (caffeine,
Run, devices, Open In, the bell). A **⋯ menu** offers Close, Archive, Move to Window and Details.

**The footer goes.** Under the header is the main area's tab row, with underlined tabs. Its trailing end holds the
openers: Terminal, Files and Diff always, then Media, Grill and each PR (with its number) only when the session
has some, then the panel toggle. A filled opener is in front, outlined is open behind, plain is not open
(ADR-079's states). The right panel has its own row of tabs.

### Where views open
- **The `+` menu adds to its own area.**
- **Chords, opener buttons and agent tools** (`show_image`, `ask_round`, `run_in_terminal`, terminal file links)
  front a view that is already open, wherever it is. Otherwise they open it **in the right panel**, and show the
  panel if it is hidden. Holding ⌥ with a chord opens it in the main area. Nothing but the reader adds a tab to
  Claude's area.

### Closing and the keyboard
- **⌘W closes the focused tab.** On the Claude tab it closes the session through
  [[ADR-037 Close Quit and Exited Flows]]'s sheet. The header's ⋯ menu and a ✕ shown on hover over an open
  sidebar card do the same. All three go through `TabStore.close`.
- **⌘1–9 pick tabs in the focused area.** ⌃⇥ / ⌃⇧⇥ cycle sessions most recently used first. ⌥⌘↑ / ↓ walk the
  sidebar's open sessions in order. ⌘K still jumps anywhere.

### Only sessions hold terminals
- **No standalone shell tabs.** *New Shell* becomes *New Terminal Tab* in the selected session, keeping its chord.
  It is disabled with no session in view. The home screen ([[ADR-120 The Empty Screen Is A Home]]) loses its New
  Shell card, leaving New Session, New Chat and Add Project. The clone sheet's *Connect in a Shell* and *Open
  Shell Here* ([[ADR-168 A Project Can Arrive From A Git URL]]) hand off to Ghostty or Terminal through the
  existing *Open in Ghostty* path.
- **No replay tabs.** Clicking a session that isn't running still resumes it. *Replay…* (⌥⌘R) opens the session
  not running instead: the replay fills its Claude tab, its saved views come back beside it, and the header offers
  **Resume**.

### The sidebar shows the workspace
An open session's card gains a row of small glyphs, one per tab: the main area's, a divider, then the right
panel's when it is showing. Compact rows stay one line.

### A workspace is remembered
Each session's layout is saved, keyed by session id: its tabs and which area each is in, open files, PR refs, run
keys, the front tab of each area, and whether the right panel is showing. It comes back when the session is
reopened, resumed or replayed. **Terminals are not saved.** A fresh shell with no scrollback is not the one you
had. The panel's width stays one shared value (`ClinicPanelWidth`), so switching sessions does not move the
divider.

## Consequences
- **Model.** `Tab` stays the per-session object a window shows (one per session, [[ADR-041 One Tab Per Session]]).
  `SidePanel` becomes two pane groups, `main` and `right`. The agent surface becomes the pinned first pane of
  `main` (a new `PanelPane.Kind.agent`), and a replay is that pane in a read-only form. `Tab.Kind.shell` and
  `.replay` go. Each group hosts only its front pane, as ADR-079's host did, and the agent surface is still never
  re-parented ([[ADR-019 Window and Surface Lifetime]]). It is occluded when another main tab is in front.
- **Persistence.** A Foundation-only `WorkspaceLayout` (Codable) in ClinicCore, saved beside the session state.
  Terminal panes are filtered out on save.
- **Focus.** [[ADR-197 Only The Tab On Screen Takes The Keyboard]]'s `isOnScreen` now means the selected session
  in its window, and a pane is on screen only when it is the front pane of a visible area. Agent tools open in
  the right panel, so they cannot cover the session being typed into.
- **Moving a session to another window** moves its whole workspace ([[ADR-072 Multiple Windows]]).
- **Attention.** "Looking at it" ([[ADR-066 Attention]]) stays the selected session in the active window, whichever
  tab is in front.
- **Lost:** seeing several sessions' titles in one strip at a glance (the sidebar cards replace it), and the
  Home screen's one-click shell. Smoke seams that open a shell tab (`-ClinicOpenShellOnLaunch`) need a session
  to live in.
- **Not doing (yet):** dragging tabs between areas, splits inside an area, a bottom area, and moving a tab to
  another session.

## Build order
1. Two pane groups per session with Claude pinned. The session tab bar and footer go, and the header comes in.
2. The opener rule with ⌥, ⌘W, ⌘1–9, ⌃⇥ and ⌥⌘↑ / ↓.
3. Shell and replay tabs removed and their entry points rehomed. Replay in the Claude tab.
4. Sidebar card glyphs and the hover ✕.
5. Saved layouts.

## Step 1, as built (2026-10-15)
- **Model.** `SidePanel` is now one tab area: `Tab.main` (`isMain`, always visible, no selection = Claude) and
  `Tab.panel`. `Tab` answers for the whole workspace: `pane(kind)`, `isOpen`, `isFront`, `frontPanes`,
  `area(of:)`, `syncOcclusion(hidden:)`, and `focusedArea`, the area the reader last acted in. "The one used
  last" spans both areas through `PanelPane.frontedAt`, one clock for every pane. `TabStore` gains `movePane`,
  `selectClaude` and an `area:` on `showPane` / `addPane`. Every opener still defaults to the right panel.
- **Host.** `TabContentView` splits two `PaneHostView`s (formerly `SidePanelHostView`). The main one holds
  Claude's surface for the tab's life in a layer of its own, shown while the pinned tab is in front and
  occluded otherwise. It is never handed to `SurfaceHostView.show`, which would re-parent it.
- **Chrome.** `MainTabStrip` (underlined tabs, a `+` that adds beside Claude, then the openers, zoom and the
  panel toggle) and `WorkspaceHeader` / `SessionHeader` in the toolbar's `.navigation` item
  (`WorkspaceViews.swift`). `TabBarView`, `TabFooter`'s view, `PaneToggle`, `FooterToggle` and the *Show Tab Bar*
  menu item and setting are gone. Every tab has a move button beside its ✕ (`TabMoveButton`) as well as
  *Move to …* in its menu.
- **Files allows several**, as ADR-198 anticipated. A Files tab is named by the file it has open.
- **The window has no title.** The toolbar draws the window's title whatever its `titleVisibility`, and
  `.toolbar(removing: .title)` also takes away the flexible space that keeps the controls at the trailing
  edge. So `.navigationTitle("")`, and `WindowState.title` is computed from the model for *Move to Window ▸*.
  The Window menu lists these windows without a name.
- **The header is capped at 290 pt.** A toolbar item is as wide as it asks to be, and the controls after it
  overflow into a » menu rather than squeeze it. The meta line shows the branch, not the project, beside the
  project's icon.
- **Zoomed, the right panel's strip shows the unzoom button**, since zoom hides the main strip that holds it.
- **Until step 3**, shell and replay tabs have no row anywhere. They are still reached through the Tabs menu,
  ⌘1–9 and ⌃⇥.

### Verification
`make test` passes (714 ClinicCore, 7 GhosttyBridge). Driven in Clinic Dev through the accessibility API,
with screenshots of each step: a shell tab and a Haiku session (`-ClinicSessionOnLaunch`). The header shows
the title, a *Finished* pill, the branch, Haiku 5.5 ▾, Medium ▾ and 4 %, and the toolbar fits a 1440 pt window
with nothing in overflow. The openers open Files, Diff and Terminal in the right panel and show their state.
The `+` adds Diff, Files and a terminal beside Claude, with a second Files tab as *Files 2*. A Diff and a live
shell moved from the right panel to the main area keep their state, and the panel hides when emptied. The Claude
tab brings the session back. Zoom and unzoom work from both strips. After the panel is shown and hidden, the
keyboard is in the main area's front shell.

Not checked: two sessions with different workspaces in one window, multiple windows, runs, PR panes, Grill
rounds arriving in a background tab (ADR-197), file links from the terminal (ADR-192), and the Media pane.

