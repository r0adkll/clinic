---
status: accepted (built 2026-10-15)
date: 2026-10-15
amends: "[[ADR-212 A Session Is A Workspace Of Tabs]] (its keyboard section, built), [[ADR-036 Keyboard Shortcuts]] (⌘1–9, ⌘W), [[ADR-073 Rebindable Shortcuts]] (new actions)"
tags: [adr, keyboard, tabs, sessions]
---
# ADR-220: The keyboard reaches tabs and sessions

## Context
Step 2 of [[ADR-212 A Session Is A Workspace Of Tabs]]: ⌘W closes the focused tab, ⌘1–9 pick tabs, ⌃⇥ cycles
sessions by recency, ⌥⌘↑ / ↓ walk the sidebar, and ⌥ with an opener's chord opens it beside Claude.

Building it, ⌥⌘↑ / ↓ turned out to be [[ADR-188 The Diff Panel Is For Reviewing]]'s next and previous changed file,
and ⌥⌘J — the Terminal opener with ⌥ — shows and hides the panel. The user chose ⌃⌥⌘↑ / ↓ for walking sessions
(2026-10-15).

## Decision
- **The keyboard's area** is where the first responder is (a panel page or shell, a main-area page or shell, or
  Claude's surface), else the area the reader last acted in.
- **⌘W closes the tab in front of that area.** On Claude it closes the session through the close sheet
  ([[ADR-037 Close Quit and Exited Flows]]). A file or image window that is key still closes first, as before.
- **⌘1–9** select that tab in the keyboard's area. In the main area, 1 is Claude. **⌘⇧] / ⌘⇧[** cycle the same
  area, Claude included. ⌘⌃] / ⌘⌃[ / ⌘⌃W stay the right panel's own.
- **⌃⇥ / ⌃⇧⇥** move through the window's sessions, most recently used first. Held ⌃ walks on, as ⌘⇥ walks apps.
  Letting go settles on the session reached, which then counts as the most recent. Chosen from the menu, the
  switch settles at once, so repeated picks toggle between the last two.
- **⌃⌥⌘↓ / ↑** walk the window's open sessions in sidebar order: by project, then the project's rows. A tab that
  is not a session goes last.
- **⌥ with an opener's chord opens the view beside Claude**: *Panel ▸ Beside Claude ▸* Terminal (no default chord),
  New Terminal ⌥⌘⇧J, Diff ⌥⌘⇧G, Files ⌥⌘⇧E, Media ⌥⌘⇧I, Grill ⌥⌘⇧K, Pull Request ⌥⌘⇧P. A view that is open in the
  right panel moves beside Claude, rather than being fronted where it is. Each is a rebindable action, so Ghostty's
  own binding on the chord yields ([[ADR-173 Clinic's Chords Outrank Ghostty's Defaults]]).
- **The Tabs menu** is now Next / Previous Tab, Tab 1–9, then Next / Previous Session, Next / Previous Open Session
  in Sidebar, and Move Session to New Window (renamed from *Move Tab*).

## Consequences
- ⌘1–9 no longer jump between sessions. ⌃⇥, ⌃⌥⌘↑ / ↓, ⌘K and the sidebar do.
- Sidebar order is approximated from the project order and each project's rows. A project inside a group that is
  folded still counts in its place.

## Verification
Driven in Clinic Dev through the menu bar by the accessibility API, with a Haiku session and a shell tab. *Next
Session* toggled between the two, and so did *Next Open Session in Sidebar*. *Beside Claude ▸ Files* opened Files
in the main area. *Panel ▸ Diff* then *Beside Claude ▸ Diff* moved Diff from the panel to the main area. *Tab 1*
fronted Claude. *Tab 3*, then *Close Tab*, closed Diff and left Files in front. Not run: ⌘W on Claude (its close
sheet is modal), and holding ⌃ to walk further than one session, since this session cannot send keys.
