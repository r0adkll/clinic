---
status: accepted (built 2026-10-15)
date: 2026-10-15
supersedes: "[[ADR-212 A Session Is A Workspace Of Tabs]] (the footer folded into the header)"
tags: [adr, ui, header, footer]
---
# ADR-216: The footer returns under both areas

## Context
[[ADR-212 A Session Is A Workspace Of Tabs]] removed the footer and put its facts in the toolbar header: project ·
branch · model ▾ · effort ▾ · context, under the title, capped at 290 pt so the toolbar's controls would fit. User
(2026-10-15): *"The top bar with all the session info feels cramped now. I liked the model/effort/dir in the
bottom bar more (it should be under all panels). We should add context % down there too and keep the top bar as
project icon, session name, project name, status and kebob menu for session actions"*.

## Decision
- **The header** is the project's icon, the session's name over its project's name, the state pill, and the ⋯ menu
  (Close Session…, Archive, Details…, Move to Window).
- **The footer** (`TabFooter`) returns as a bar across the bottom of the session, under the main area and the right
  panel both. Leading: model ▾, effort ▾ and the working directory, which a click copies, as before ADR-212.
  Trailing: the context gauge, the CLI's own percentage ([[ADR-157 The Status Line Reports Context]]), drawn as on
  the session cards ([[ADR-158 The Card's Meta Line Gives Way And Draws A Gauge]]).
- **No openers in the footer.** [[ADR-213 The Plus Menu Replaces The Openers]] stands.

## Consequences
- The branch is no longer in the header. The session's card in the sidebar shows it.
- The header asks the toolbar for less width, so the controls after it have more room.
