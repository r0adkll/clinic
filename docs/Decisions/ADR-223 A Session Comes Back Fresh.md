---
status: accepted (2026-10-16)
date: 2026-10-16
supersedes: "[[ADR-212 A Session Is A Workspace Of Tabs]] (a workspace is remembered; build step 5)"
tags: [adr, ui, tabs, persistence]
---
# ADR-223: A session comes back fresh

## Context
[[ADR-212 A Session Is A Workspace Of Tabs]] planned to save each session's layout (its tabs and their areas, open
files, PR refs, the front tab, the panel's visibility) and restore it when the session was reopened, resumed or
replayed, as build step 5. User (2026-10-16), when step 5 came up: *"I think its okay to not restore tab layouts
when restoring session. I kinda like resetting the view when coming back to a session cold"*.

## Decision
- **No saved layouts.** A session that is opened, resumed or replayed starts with Claude alone and the right panel
  hidden, as [[ADR-079 Panel Tabs]] always had it.
- **A workspace lasts as long as its tab.** While a session is open its tabs stay as they were, across switching
  sessions and moving it to another window. Closing it lets them go.
- **The panel's width stays one shared value** (`ClinicPanelWidth`), as before.

## Consequences
- Nothing is written per session, and there is no layout to go stale when a file or PR it named is gone.
- A replay's views beside it are opened by hand each time ([[ADR-221 Terminals Live In Sessions And Replays In
  Their Claude Tab]]).
- ADR-212's build order ends at step 4.
