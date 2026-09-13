---
status: accepted (built 2026-09-13)
date: 2026-09-13
amends: "[[ADR-078 Open In Targets and Quick Action]] (who decides the list, and what the toolbar picker sets)"
tags: [adr, ui, open-in, settings, milestone-4]
---
# ADR-147: Open In is configured, and the choice is the project's

## Context
User (2026-09-13): *"Should we add a settings panel to configure these available apps? Also can we make
them configurable per project?"*

Asked while fixing [[ADR-146 Two Installs Of One App Are Two Targets]], which is the part of the
complaint that was a defect. What is left are two real limits of [[ADR-078 Open In Targets and Quick
Action]]:

- **The list is a constant.** Six editors, compiled in. Sublime, Fleet, Emacs, Neovide, an in-house
  tool — none can be reached, and nothing in the UI admits the list is closed.
- **The pick is global.** One `ClinicOpenInDefault` for every project, when the whole point of a session
  manager is that projects differ. An Android checkout wants Studio; Clinic wants Xcode; a web app wants
  VS Code. Choosing again every time you switch projects is choosing nothing.

## Decision

### Two different questions, two different places
The two halves of the request are not the same question and must not share an answer:

| | Question | Belongs to | Where |
|---|---|---|---|
| **Which apps exist** | what is installed on this Mac | the machine | Settings |
| **Which app to use** | what this checkout opens in | the project | the toolbar picker |

Conflating them would mean a project able to invent an app, or Settings having to be visited to change
one project's editor. Each is set where it is true.

### Settings adds to discovery, it does not replace it
A sixth pane, *Open In*, listing every target with its icon, its name and **where it lives** — the only
thing that separates two installs of one app. Each row can be hidden from the menus, and one is the
global default. Discovery still runs and still leads: the pane's job is to *add* what discovery cannot
know about, not to curate what it found. For most people it stays a list they never edit, which is the
sign it is the right size.

- **Add App…** takes any bundle. It is stored as a **path**, not a bundle id, so a moved app stops
  resolving rather than quietly opening something else — and ADR-146 has just shown what a bundle id
  costs when two apps answer to one.
- **Only reader-added apps can be removed.** A discovered app can only be hidden; removing it would be a
  lie, because the next refresh brings it back.
- **The default cannot be hidden**, or the toolbar button would open something the reader had just said
  to stop showing.

### The toolbar picker picks for the project
With a project in view the picker's header reads *"Open this project with"* and the choice is written to
`ClinicState.openInByProject`, keyed by project path. With no project — a directory Clinic has not
registered — it sets the global default, which is the only thing such a directory could mean.

An override adds one row: **Use Default (*name*)**, which clears it. Without that the override would be a
one-way door, since every other row sets a new one.

This is the shape of [[ADR-118 Where A Worktree Branches From]] — per project, falling back to a
Settings-wide default — and it uses the same machinery `runSelectionByProject` and
`worktreeBaseByProject` already use.

### The pick is personal, not committed
It goes in Clinic's own state, **not** in `.clinic/` beside the run configurations of
[[ADR-122 Projects Have Run Configurations]]. A run configuration is a fact about the project that the
whole team shares; which editor *you* open it in is a fact about *your* Mac, and naming an app a
teammate has not installed would be worse than saying nothing. It also keeps Open In out of `git status`.

An id that no longer resolves — the app deleted, or hidden since — falls back to the global default
rather than leaving the button dead.

## Consequences
- `OpenInApps.targets` is now a filtered view and `allTargets` is the whole list; the Settings pane is
  the only caller of the latter. Menus and the toolbar see only what is shown.
- `OpenInToolbarMenu` needs the `SessionStore` and the tab's project path, so both are threaded through
  `RootToolbar` → `TabControls`. That is three structs carrying two fields for one control's benefit; it
  is the cost of the toolbar being built from plain values rather than the environment, which ADR-078
  chose deliberately.
- **Reordering is not offered.** The curated order of ADR-078 stands and added apps go last. A list of
  seven does not need drag-and-drop, and hiding covers the real complaint (too many rows, not the wrong
  order). Worth revisiting only if someone asks.
- Hidden apps and added apps are global, not per project. A per-project *list* would be the conflation
  this ADR exists to avoid.
- The `OpenInMenu` submenu on sidebar and project rows is unchanged: it opens a target directly and has
  never had a default to set.

## Verification
Driven through the accessibility tree (Screen Recording is still declined for Claude Code), on a smoke
instance with its own `CLINIC_APP_SUPPORT`.

- **The pane lists every install with its location**: *Finder*, *Ghostty*, *Xcode* `/Applications`,
  *Visual Studio Code* `/Applications`, *IntelliJ IDEA* `~/Applications`, *Android Studio*
  `~/Applications` — marked **Default** — and *Android Studio Preview* `/Applications`, each with a
  *Make Default* link and a *Show … in Open In menus* checkbox. The default's checkbox is disabled.
- **The ADR-146 migration ran on real preferences**: the stored `ClinicOpenInDefault` was the bundle id
  `com.google.android.studio` and came back as `/Users/r0adkll/Applications/Android Studio.app` — the
  release build, not the Preview that Launch Services had been choosing.
- **The picker is the project's**: its header reads *"Open this project with"* and lists all seven
  targets, with no *Use Default* row while there is no override.
- **A pick takes, persists and clears**: pressing *Android Studio Preview* changed the toolbar button to
  *Open in Android Studio Preview* and wrote
  `openInByProject: {"/Users/r0adkll": "/Applications/Android Studio Preview.app"}` to `state.json`; the
  reopened picker then offered *Use Default (Android Studio)*, which reverted the button and left
  `openInByProject: {}`.
- `make build` clean, 460 ClinicCore tests pass. Smoke instance and its App Support removed.
- **Appearance unverified**, as with ADR-133 onward: the pane's rows and spacing have not been seen.
- **Not verified**: *Add App…*, which opens an `NSOpenPanel` that the accessibility harness cannot drive
  end to end, and actually opening a folder in each install.
