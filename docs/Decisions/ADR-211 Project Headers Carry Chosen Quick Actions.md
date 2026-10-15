---
status: accepted (built 2026-10-15)
date: 2026-10-15
amends: "[[ADR-050 Project Decoration and Actions]] (the header's hover buttons are chosen, not fixed to + and ⋯), [[ADR-108 The Settings Window Is A Source List]] (General gains a section)"
tags: [adr, ui, sidebar, projects, settings]
---
# ADR-211: Project headers carry chosen quick actions

## Context
User (2026-10-15): *"Can we add some project hover-quick-actions (maybe with an optional settings group/panel
that let's us add customize a max # of quick actions on projects) for adding (removing) from a group, Git pull,
etc)"*

A project header showed two buttons under the pointer, *+* and *⋯* ([[ADR-050 Project Decoration and Actions]]).
Everything else, including the *Move to Group* that [[ADR-210 Projects Can Be Grouped And A Window Scoped To A Group]]
had just added, was a level down in the menu.

## Decision
- **Eleven actions to choose from**, each one already in the project menu: New Session, New Session in
  Worktree, Continue Last Session, Open Shell Here, Run ▸, Open In, Git Pull, Move to Group ▸, Open on GitHub,
  Copy Path and Show in Finder. Two of them open menus: *Run* lists the project's configurations (or offers to set
  them up), and *Move to Group* lists the groups with *New Group…* and *Remove from Group*. *Open In* opens
  straight in the project's own target ([[ADR-147 Open In Is Configured And Per-Project]]). The rest act in one
  click.
- **Defaults:** New Session (the old *+*), Move to Group and Git Pull, the two the user named.
- **At most five, in a fixed order, then ⋯.** The menu keeps every action whatever is chosen, so nothing is lost
  by leaving one out. The cap is a fixed limit rather than a setting: a "max" control beside a checklist would
  repeat the checklist. Once five are on, the other switches disable. The order is the list's, not the order
  they were switched on; reordering was left out until it is wanted.
- **Chats shows only what needs no repository:** New Session, Continue Last, Open Shell, Copy Path and Show in
  Finder.
- **Settings ▸ General ▸ Project quick actions**, below Window. Each action has a switch with its glyph and a
  line on what it does, plus *Restore Defaults*, and a footer giving the count. Every project menu ends with
  *Customize Quick Actions…*, which opens that pane.
- **The buttons take room only while hovered.** ADR-050's header reserved the space of its two buttons so it
  never reflowed. Reserving up to six would cut every name short all the time. Now a short name doesn't move,
  and a long one truncates while the pointer is on it. The buttons are collapsed to zero width rather than
  removed, so an open menu keeps its anchor when the pointer moves into it.
- Stored as a comma-separated list under `ClinicProjectQuickActions`. Nothing stored means the defaults; an
  empty string means none. `ProjectQuickAction` parses, orders and caps it in ClinicCore, with tests.
- `MoveToGroupItems` and `ProjectRunItems` were taken out of their submenus, so the quick actions and the project
  menu list the same items.

## Consequences
- Settings window toggles have no accessibility title (SwiftUI puts the label beside the switch). This was
  already true of the pane's other switches. A smoke run finds them by position.

**Verified.** `make test`: 714 pass, 6 of them new in `ProjectQuickActionTests`. Clinic Dev, with the hover
state seeded by a temporary launch argument (removed before committing), showed *+ ⧉ ⤓ ⋯* on `proj` and *+ ⋯* on
Chats. The Settings section showed the three defaults on. Turning on two more through AX stored
`newSession,openShell,run,gitPull,group`, and the other six switches disabled at the cap. The keys the run wrote
to Clinic Dev's preferences were deleted afterwards. **Not verified:** each action's click, and the Run and
Group menus opening from the header. Try those by hand.
