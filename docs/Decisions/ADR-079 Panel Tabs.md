---
status: accepted
date: 2026-09-08
tags: [adr, ui, panel, milestone-4]
---
# ADR-079: The right panel is a tab strip

## Context
The right column showed exactly one page: git ([[ADR-052 Git Page]]), a PR ([[ADR-053 Pull Request Page]]), attachments ([[ADR-056 Session MCP Tools]]) or the editor ([[ADR-057 Editor Panel]]), while the extra shell lived *below* the agent surface ([[ADR-046 Terminal Panel]]). Opening git closed the PR you were reading; the editor's file selection and the PR's section survived only by luck; and each footer button meant two things at once ("which page" and "is a page showing"). User (2026-09-08): the right split panel "should be more generic with Tab support so when you click git, prs, files, terminal, or attachments it adds a new tab into the panel for that view".

## Decision
- **One panel per session tab, holding an ordered strip of panes.** Kinds: `terminal`, `git`, `files`, `attachments`, `pr(ref)`. At most one pane per kind, so a quick action re-focuses what it already opened; PRs are keyed by their ref, so each PR gets its own pane. `SidePanel` (panes + selection + visibility) and `PanelPane` (kind + its long-lived model — `GitPageModel`, `EditorModel`, or a libghostty surface) replace `Tab.rightPane` / `gitPage` / `editor` / `panelSurface`.
- **The quick actions are openers, not toggles.** Footer chip or shortcut → show the panel with that pane in front: open it if it is not there, front it if it is, reveal the panel if it is hidden. They never hide anything and never destroy a pane, so the same click always lands you in the same place. Chip states: filled = on screen, outlined = open behind another pane, plain = not open.
- **Hiding is its own control, always present.** One chevron, pinned to the trailing edge of the session tab bar, toggles the panel whatever it holds — mirrored by a Show / Hide Panel menu item and ⌘⌥J. The strip does not repeat it. Visibility is therefore independent of content: closing the last pane leaves the panel open on an empty state that offers the same views the `+` menu does.
- **The strip is the chrome.** A SwiftUI tab bar over the content, the height of the session tab bar and using `TabChip`'s metrics (callout title, 10/4 padding, 220 pt cap) so both strips read as the same control: chips with a close ✕ and a `+` menu of the kinds not yet open. Context menu: Close, Close Others. New **Panel** menu with the five openers plus Show / Hide Panel and Next / Previous / Close Panel Tab (⌘⌥J, ⌘⌃] / ⌘⌃[ / ⌘⌃W); the pane shortcuts (⌘J, ⌘⇧G, ⌘⇧E, ⌘⇧I, ⌘⇧P) keep their chords and move to a "Panel" section in the shortcut editor ([[ADR-073 Rebindable Shortcuts]]).
- **The shell moves into the panel**, superseding ADR-046's placement: no more `VSplitView` under the agent surface, no `ClinicPanelSplit` autosave. ⌘J is now "the terminal pane". Multiple shells, splits and persisted scrollback stay deferred.
- **Only the front pane is hosted.** `SidePanelHostView` keeps one `NSHostingView` for the page and one host for the shell surface; switching panes swaps the hosted root view and hides the other. Panes that are not on screen stop their git watcher and idle; the shell surface is only occluded, never freed. The agent surface is still never re-parented ([[ADR-019 Window and Surface Lifetime]]).
- **Width**: each kind carries a minimum (files 520, terminal 400, git/PR 380, images 320), and fronting a wider pane widens the panel rather than shrinking the terminal past its own 360 pt floor. The width the user drags to is remembered in `UserDefaults` under `ClinicPanelWidth` — one width shared by every tab and window, restored when the panel is shown again and across launches. `NSSplitView`'s own autosave cannot do this, because hiding takes the panel out of the split view entirely; the `ClinicRightPane` autosave is gone.
- **Not persisted.** A tab starts with the panel hidden and no panes; agent tools (`show_image`, `run_in_terminal`) go through the same opener, so they can never hide the panel out from under the user.

## Consequences
- Reading a PR while the editor is open is now normal; the footer says which of them is on screen.
- Everything hosted in the panel is pinned with constraints and laid out synchronously the moment it joins the split view — an `NSHostingView` first sized at zero renders blank until something forces another pass, which showed up as a panel that only appeared after dragging the divider.
- Switching panes still rebuilds the SwiftUI page, so view-local state (the PR page's section picker) resets — the models that matter (editor buffer, git status) live on the pane and survive.
- If per-pane state or several shells are wanted later, `PanelPane` is the place to hang them; the strip already supports arbitrary panes.
