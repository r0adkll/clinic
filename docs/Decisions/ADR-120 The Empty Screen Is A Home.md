---
status: accepted
date: 2026-09-11
tags: [adr, ui, navigation]
---
# ADR-120: The empty screen is a home

## Context
User (2026-09-11): *"Let's enhance the UI/UX of the "empty" screen when no session or screen is
selected. Including some quick actions for adding projects, starting empty chats, or maybe some
keyboard shortcut suggestions."*

A window with no tabs showed a `ContentUnavailableView`: *No session open. Pick a session from the
sidebar, or press ⌘N to start a new one.* That is not an edge case. [[ADR-042 Launch Restoration]]
restores geometry, not tabs, so unless *Reopen the last session on launch* is on, every launch lands
on this screen, and so does closing the last tab. It is the most-seen screen in the app, and it
offered one chord and a pointer elsewhere.

## Options
Drawn as mockups on a design canvas in the user's own appearance (dark, red accent, their real
sidebar), beside a screenshot of the old screen:
- **A · Launchpad**: the app icon over a grid of six start actions with their chords. Cheap and
  needs no data, but it is the same every launch and says nothing about your work.
- **B · Resume**: start actions, anything waiting on you, the most recent sessions across every
  project, one shortcut tip. **Chosen.**
- **C · Composer**: the [[ADR-082 New Session Screen Composer]] card as the home screen, with a
  project picker. The fewest steps to working, but it duplicates the New Session screen and picks
  a project for you; a prompt sent to the wrong repository costs more than the click it saves.
- **D · Shortcut sheet**: start buttons over a cheat sheet read from `KeyBindings`. Teaches for a
  week, then it is noise.

## Decision
- **Centred, under the app's name.** The app icon (72 pt) and *Clinic* (34 pt bold, larger than
  `.largeTitle` at the user's request) sit centred above the content, and the whole block is
  centred in the pane; a window too short for it scrolls from the top. The first build anchored the column 64 pt from the top with no header. The user asked to
  *"center the content of this screen, and put the app logo / title above the content too"*.
  The first-launch state takes the same header.
- **Start**: four cards across the top: New Session, New Chat, New Shell, Add Project…. Each has
  an accent tile (the [[ADR-111 Nav Rows Wear Accent Tiles]] look at 30 pt), its chord top-right
  and its title underneath. They run the same commands as the menu, and the chords are read from
  `KeyBindings`, so a rebinding ([[ADR-073 Rebindable Shortcuts]]) shows here too. They wrap to two
  by two when the pane is too narrow for four.
- **Needs you**, shown only when something is waiting: a session in any window whose hook state is
  waiting for permission or input, then detached sessions that need you ([[ADR-061 Background
  Agents]]). Rows are orange because orange is what "needs you" already wears in the sidebar.
- **Recent**: the five most recently active visible, unarchived sessions across every project.
  The sidebar groups by project, so this is the one place where "what was I doing?" is a single
  glance. **One click resumes the session**, the same as a sidebar row (`TabStore.reveal`): a
  session already open in a tab is brought forward instead. On hover the time becomes *Resume*, or
  *Show* for an open one. The header carries *Find any session* with the jump chord.
- **One tip per launch**: a chord and what it does, from a short list. The list is filtered to
  commands that still have a chord, and the tip is fixed for the life of the process, so closing
  the last tab twice does not reshuffle it. *All Shortcuts…* opens Settings on the Shortcuts pane.
- **First launch**: when no project is registered besides Chats, the recent list has nothing to
  show, so the screen becomes a folder drop target with *Choose Folder…*, plus New Chat, New Shell
  and *Import a Session* (the jump switcher). The drop is accepted anywhere in the pane, and **only
  in this state**: the user did not want the whole window to be a drop target once projects exist.
- While the first scan is still running the roster is empty (Chats is always pinned once it has
  run, per [[ADR-077 Persistent Projects and Sidebar Polish]]), so the screen draws nothing rather
  than flashing the first-launch state at everyone.

## Consequences
- `HomeScreen.swift` replaces the `ContentUnavailableView` branch of `DetailView`.
- `ProjectFolderPicker` is the one NSOpenPanel behind every *Add Project*; the sidebar toolbar uses
  it too.
- `PreferencesView.open(_:)` opens Settings on a given pane, or switches an open Settings window to
  it.
