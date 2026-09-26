---
status: accepted
date: 2026-09-26
amends: "[[ADR-079 Panel Tabs]] (what the empty state shows)"
tags: [adr, ui, panel]
---
# ADR-172: The empty panel offers views with reasons

## Context
User (2026-09-26): *"Let's do a UX improvement pass on the empty right panel."*

[[ADR-079 Panel Tabs]] gave the panel an empty state that "offers the same views the `+` menu does",
and [[ADR-130 Shift-Click Closes A Tab]] made it something the reader only ever asks for (the tab bar's
chevron or ⌘⌥J with nothing open). It was a stock `ContentUnavailableView` ("Nothing open here") over a
column of bordered buttons, and:

- **Each button was a bare name.** "Diff", "Files", "Images" said nothing about what they would show
  for *this* tab, though the facts were already known: the branch, the folder, how many images the
  session has, how many Grill questions are waiting.
- **Every chord was hidden.** The panel is where the pane shortcuts (⌘J, ⌘⇧G, ⌘⇧E, ⌘⇧I, ⌘⇧P) matter,
  and the one screen that lists the panes did not show them.
- **Pull requests and runs read as refs.** They used `defaultTitle`, so a PR was "#412" and a run was
  its configuration id, mixed in with the fixed views.
- **Nothing said how to leave**, though getting out of the way is the other thing an empty panel is for.

## Decision
`SidePanelEmptyState` becomes a small home in [[ADR-120 The Empty Screen Is A Home]]'s language:
centred when it fits and scrolling from the top when it does not, 420 pt wide at most.

- **Header:** *Open beside the session*, then one line saying views open as tabs here and their
  shortcuts work anywhere in the tab.
- **Views:** one row per openable view: an `AccentTile` ([[ADR-111 Nav Rows Wear Accent Tiles]]'s
  accent glyph on accent wash), the title, a line of what it would show, and the live `KeyCap` for its
  chord, read through `KeyBindings` so a rebinding shows ([[ADR-073 Rebindable Shortcuts]]). The lines:
  *A shell in ‹folder›*, *Changes on ‹branch›, by turn or branch*, *Browse and edit ‹folder›*, *N images
  from this session* and *N questions waiting for you*. Waiting questions are drawn in the sidebar's
  orange ([[ADR-096 Session Status Indicators]]). Only facts already in memory are used; nothing is fetched.
- **This session:** the session's pull requests, newest first, drawn with their service's glyph
  ([[ADR-116 The PR Panel Speaks Its Service's Visual Language]]), titled *#n title* with the repository
  and state underneath. The newest one carries ⌘⇧P, because that is the PR the chord opens. Titles come
  from `PRStore.ensureLoaded`. After the PRs come the checkout's runs, with their status glyph and
  status. The section is left out when there are none.
- **Footer:** *Hide ⌥⌘J · Zoom ⌥⇧⌘J* as key caps.
- **Rows open through the same openers as the menu and the chords.** Grill goes through `toggleGrill`,
  so it takes the keyboard as it does from ⌘⇧… ([[ADR-139 A Round Takes The Keyboard]]).

The panel's hosting roots now receive `KeyBindings` in their environment. Until now no panel view needed it.

## Consequences
- The empty panel is the one place that lists all of the panel shortcuts together, so it also teaches them.
- A hidden launch key, `-ClinicShowEmptyPanelOnLaunch YES` (with `-ClinicOpenShellOnLaunch YES`),
  shows the panel with nothing in it, for smoke runs.
- Not doing: arrow-key navigation of the rows, because the chords already open each view from anywhere,
  and a placeholder in the empty tab strip, which keeps only its `+`.
- Verified in a smoke instance (own `CLINIC_APP_SUPPORT`, a shell tab, the new key): the header, the
  three views a shell tab can hold with their chords and live lines (*Changes on main…*), and the
  footer, centred in the panel. The real `com.r0adkll.clinic` defaults were unchanged afterwards. Not
  run: a session tab with PRs, runs or waiting Grill questions.
