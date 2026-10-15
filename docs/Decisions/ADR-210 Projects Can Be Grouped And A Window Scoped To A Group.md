---
status: accepted (built 2026-10-15)
date: 2026-10-15
amends: "[[ADR-025 Vocabulary]] (adds Group), [[ADR-062 Project Groups]] (collapse-all and expand-all fold groups too), [[ADR-077 Persistent Projects and Sidebar Polish]] (ungrouped projects, then groups, in place of one flat list)"
tags: [adr, ui, sidebar, projects]
---
# ADR-210: Projects can be grouped, and a window scoped to a group

## Context
User (2026-10-15): *"I'm starting to collect quite the list of projects in my sidebar and I want to explore
creating project groups. Lets iterate on how this might look and be implemented"*

The user's live sidebar had 12 projects, 11 of them collapsed: folding was already doing the work groups would do.
ADR-062's "project groups" are projects as groups of *sessions*; nothing grouped projects.

Three directions were mocked from the user's real projects on a design canvas
(https://claude.ai/artifact/92FJoT4aiaUaxm8u9ipBnr):
- **A · Sections**: Finder-style captions above ordinary project headers.
- **B · Folders**: a group as a row with a 2×2 tile of its members, its projects on a guide line beneath.
- **C · Workspaces**: chips that narrow the list to one group.

The user liked A and C and asked for both. B was dropped. It nests a level deeper in a sidebar where ADR-077
rejected an indent at every depth it tried.

## Decision
Two rounds of questions, every recommendation accepted:

- **A group is a named set of projects the user makes.** Each project is in at most one group, and nothing is
  grouped automatically: nearly every project here lives in `~/SoftwareProjects/main`, so grouping by folder
  would make one group of everything. Chats is Clinic's own and never joins a group.
- **The All scope is A.** Chats, then ungrouped projects with no header, then each group under a caption: its
  name in small caps, its project count, and a chevron. Clicking the caption folds it. With no groups the
  sidebar is exactly what it was.
- **A folded group shows its members' tiles** (up to six, then *+N*) and what its hidden sessions want. A folded
  *project* shows a dot for the same reason, so folding never hides a session that needs you. See *What counts*
  below.
- **What counts** (amended the same day). The first build counted only open tabs in a waiting state. User:
  *"I'm not seeing the "needs you" dots"*. Reproduced in Clinic Dev with synthetic hooks. A permission prompt
  did show, but a turn that ended while Clinic was in the background left the folded group blank. That case
  is idle and **unread**, the blue dot, and it is the common one. The count now matches the Dock badge plus
  what a session's glyph and card show in orange:
  - **waiting** (orange): an open tab at a prompt or a permission request; an unanswered Grill round, with or
    without a tab (a card's flame row); or a detached background agent that needs attention.
  - **unread** (blue): an open tab that finished a turn unseen and is not working again.

  Each session counts once, under the project its row is listed in. Orange outranks blue. A group's caption
  says *N need you* (all of them, while anything waits) or *N new*. A chip and a folded project show one dot
  in the same colour.
- **The chips are C.** Once a group exists, a row of chips under the Projects toolbar reads *All*, then each
  group. A group's chip shows Chats plus that group, without its caption, and ignores the group's fold. A chip
  gets an orange dot when a session in it waits, except the selected one, whose sessions are already listed.
  Chips wrap onto more lines rather than scroll, so every dot stays visible.
- **The scope is per window.** The main window's is remembered across launches (`ClinicGroupScope`). Other
  windows open on All, because only the main window's geometry is restored ([[ADR-042 Launch Restoration]]).
- **Selecting a session outside the scope moves the window to its group**, or to All for an ungrouped project.
  This covers a notification, ⌘K and anything else that selects a tab. The project is the one the row is
  listed under, which for a child session is its root ancestor's ([[ADR-181 Sessions Have Parents]]).
- **A filter searches every group.** While one is typed, the scope and the captions are set aside, the same way
  folds already are.
- **Making and moving groups:** *New Group…* in the Add menu and in View ▸ Project Group. *Move to Group ▸* in
  the project menu, with *New Group…* and *Remove from Group*. Dropping a project on a caption or a chip moves
  it into that group. Dropping it among a group's projects moves it there too, and dropping it among ungrouped
  ones takes it out. Captions drag to reorder, and the caption's ⋯ menu (also its and its chip's context menu)
  has *Show Only*, *Rename Group…*, *Move Up*, *Move Down* and *Delete Group*. Deleting removes the grouping
  only; the projects stay, ungrouped.
- **View ▸ Project Group** lists the scopes, plus *Next Group* and *Previous Group*. Both are rebindable and have
  no default chord.
- **Collapse All and Expand All** fold and unfold groups as well as projects.
- **Vocabulary:** the thing is a *group* and the narrowing a *scope*. The mockups called C *Workspaces*;
  [[ADR-025 Vocabulary]] rules out "workspace", and no label in the app uses it.

### Model
`ClinicState.projectGroups: [ProjectGroup]` (id, name, `members: Set<String>`), in sidebar order, and
`collapsedGroups: Set<UUID>`. Both are optional when decoding, so older state files load. The invariants live in
ClinicCore and are tested: one group per project, delete ungroups, a missing group id ungroups, names are trimmed
and never empty. `ProjectLayout` is the pure arrangement: pinned, ungrouped, and groups with members in the
roster's order, or one group when scoped. `ProjectRoster` still decides order, and `projectOrder` still orders
projects inside a group. A member that is archived or removed keeps its group and returns to it.

A new group's id is made before the state change is applied. `SessionStore.update` applies the closure twice,
in memory and on disk, and an id made inside it would differ between the two.

### Two list details found while verifying
- **Group sections wait for the first scan.** Drawn before the projects were listed, the captions and their
  placeholder rows stayed put when the projects arrived above them, and Chats opened scrolled out of view.
  A wrapping-layout cause and a sizing cause were tried and ruled out first.
- **The list is keyed by the scope.** Switching scope then starts at the top, instead of wherever the outline
  kept the rows the two scopes share.

## Consequences
- The design canvas holds A, B, C and A + C. It is the reference for the caption and chip styling.
- An empty group shows *Drag a project here, or use Move to Group in its menu.* under its caption, or alone when
  scoped to it.
- Group members are stored as paths. A project moved on disk leaves its old path in the group, harmlessly,
  until it is moved again.

**Verified.** `make test`: 708 pass, 13 of them new in `ProjectGroupTests`. Clinic Dev was checked by AX frames
and screenshots with two seeded groups: the All scope with Apps expanded and Tools folded showing its tiles;
launching scoped to Apps; pressing the *All* and *Tools* chips; the scope written to `ClinicGroupScope`; and
unfolding Tools through its accessibility action. Clinic Dev's `state.json` and preferences were restored
afterwards. The attention count was then verified with a real session in a folded group, driven by synthetic hooks. A
permission prompt read *1 waiting on you* (orange chip dot). A turn ended unseen read *1 new* in blue on the
caption, with a blue chip dot. A folded project holding a session with an open Grill round and no tab showed an
orange dot. **Not verified:** the scope change on selecting a session outside the scope, drag and drop, and the
menus' name prompt. Try those by hand.
