---
status: accepted
date: 2026-09-10
tags: [adr, ui, tasks, navigation, github]
---
# ADR-112: Tasks screen

## Context
User (2026-09-10): *"Let's design and develop a "Tasks" feature, a full screen issues/task list manager
through the side bar navigation. It should be able to pull the issues from Github while architecting
in a way that we can add gitlab and other task provider integrations."* Settled over four grilling
rounds the same day. Where the data comes from is [[ADR-113 Work Item Providers and Sources]], and
the issue-to-session hand-off is [[ADR-114 Starting A Session From A Task]].

The job the screen does was the first question, because it decides everything after it:
- **Viewer**: browse, search and filter issues, then open them on GitHub.
- **Viewer + launchpad**: that, plus starting a Claude session from an issue. **Chosen.**
- **Tracker**: that, plus close/reopen, assign, label, comment and create.

Clinic is a session manager. The value it can add to an issue list is turning an issue into a
session, not re-implementing GitHub's issue UI. The provider protocol leaves room for writes.

## Decision
### Scope
- **Issues only.** Pull requests already have a panel of their own ([[ADR-087 Pull Request Panel Is Status-First]]),
  so the PRs GitHub counts as issues are excluded.
- **One aggregated list across every project**, with the project as a filter, not a list per project.
  The question a full-screen page answers is "what should I work on next, anywhere?".
- UI word **Tasks**; model word `WorkItem` ([[ADR-025 Vocabulary]]).

### Entry
- `WindowState.Screen.tasks` is the **first** nav row: it is the destination used daily, and the
  other three are configuration.
- Glyph **`list.bullet.clipboard`** in the accent tile ([[ADR-111 Nav Rows Wear Accent Tiles]]).
  The grilling settled on `checklist`, but the sidebar toolbar already uses `checklist` for select
  mode ([[ADR-109 The Sidebar Toolbar Is Sized Like The Nav Rows]]), one row below. Two meanings for
  one glyph that close together would be a trap.
- **⌥⌘T**, a rebindable `ShortcutAction.tasks` ([[ADR-073 Rebindable Shortcuts]]). It sits with
  ⌥⌘M and ⌥⌘A, and View ▸ Tasks gets a menu item.
- No badge. Nothing is fetched while the screen is hidden, so a badge would have nothing current to count.

### Layout: scope column | list | detail
The other screens are two panes: header, list and detail. Tasks has more to navigate than they do,
so it gets a third pane, the **scope column** (220 pt).
- **Views**: Assigned to me · Created by me · Mentioned · All, each with a count. **⌃1–⌃4**
  switch between them. The grilling planned ⌘1–⌘4 with ⌃ as the fallback, and ⌘1–⌘9 turned out to be
  the Tabs menu's "Tab 1…9".
- **Projects**: "All Projects", then every sidebar project in roster order ([[ADR-077 Persistent Projects and Sidebar Polish]]),
  each with its count. Chats is left out.
  - The list is **flat**. The grilling assumed projects nest under "project groups", but the groups
    in [[ADR-062 Project Groups]] are the per-project sections themselves, so there is nothing to
    nest under.
- **View and project are independent selections.** A view is always active, and at most one project
  narrows it. "Assigned to me in clinic" is the main use, and one combined selection could not express it.
  Changing one never resets the other.
- **Counts follow the filters.** Each count is the number of items the current filters would show,
  so a project reads "3" when you have searched "crash" and three of its issues match.
- **A project that doesn't resolve** is dimmed, and hovering it shows why ("No GitHub remote",
  "Not a git repository"). A project whose last fetch failed shows a warning glyph, with the error in
  its help text, and its cached items stay in the list.
- Each project row's context menu has **Task Source…** ([[ADR-113 Work Item Providers and Sources]]).

### List
- **Sort**: updated (the default), created, comments or number, always descending.
- **Group by**: None (the default) or Project. The Project grouping adds a section header per project.
  Label and milestone grouping are left out, because an issue with two labels would show twice.
- **Search**: plain text over title, body, `owner/repo` and `#number`. Every term must match. A
  `#123` term matches the number exactly. There is **no token syntax**: menus cover what tokens
  would, and a half-built query language is worse than none.
- **Filters**:
  - State: Open / Closed / All. Closed items are fetched on demand ([[ADR-113 Work Item Providers and Sources]]).
  - Labels: multi-select, and an item must carry **every** chosen label, as GitHub's `label:a label:b` does.
  - Assignee, including "Unassigned".
  - Author.
  - Milestone.
  - Labels, assignees, authors and milestones with the same name are **merged by name across repositories**.
  - A Clear button appears while any filter is set.
- **Row**:
  - Line 1: a state glyph, the title in semibold, a dot when the issue changed since you last opened
    it, and the count of linked sessions ([[ADR-114 Starting A Session From A Task]]).
  - Line 2: the project icon, `repo#123`, the author, "updated 3h ago" and the comment count.
  - Up to three labels, then "+N".
- **Labels wear GitHub's colours**, as a wash of the colour behind a hairline border of it, with the
  text pushed toward the colour's readable end for the current appearance.
  - This is the one place Clinic takes colour from someone else's palette. The user chose GitHub's
    colours over neutral capsules, even though the house rule is one accent
    ([[ADR-111 Nav Rows Wear Accent Tiles]]). A label's colour *is* information here.
  - A wash, not a solid fill: solid fills turn a busy list into a wall of colour, and raw hex text on
    either appearance is unreadable for half of all labels.
- The "updated since last viewed" dot clears when the item is selected. `lastViewed` is kept per item
  in the cache ([[ADR-113 Work Item Providers and Sources]]).

### Detail
- **Native header**:
  - State, title, `owner/repo#number`, author, age, labels, assignees and milestone.
  - Actions: **Start Session** (↩), **Open on GitHub** (⌘O) and **Copy Link** (⇧⌘C).
  - Linked pull requests, from GitHub's `closedByPullRequestsReferences`.
  - Linked sessions.
- **Below the header, one web view** holds the body and the whole comment thread, with an author
  and a time on each comment.
  - It uses [[ADR-090 GitHub-Rendered Bodies]]'s document: the same CSP, stylesheet and
    link-to-browser policy.
  - It is **one** web view that scrolls itself, not one per comment the way the PR panel does. An
    issue with 80 comments would otherwise be 80 WebKit views.
- Detail is fetched when an item is selected, re-fetched on refresh, and never persisted, because
  its signed image URLs expire.

### Keyboard (screen-local)
| Keys | Action |
|---|---|
| ↑ ↓ | Move through the list |
| ↩ | Start Session (composer) |
| ⌘↩ | Start Session immediately |
| ⌘O | Open on GitHub |
| ⇧⌘C | Copy link |
| ⌘F | Focus search |
| ⌘R | Refresh |
| ⌃1–⌃4 | Switch views |

Only ⌥⌘T is rebindable. The rest belong to the screen, like the Images pane's Finder keys
([[ADR-107 The Images Pane Has A Finder Keyboard]]).

### Footer and failures
- The footer reads "Updated 2m ago · 14 sources · 312 open". When a source hits the item limit, it
  adds "showing the 1000 most recently updated in owner/repo".
- If `gh` is missing or not logged in, the whole content area shows `GitHubUnavailableView`
  ([[ADR-086 Tool Discovery and gh Availability]]).

### Per-window state
Each window has its own view, project, filters, sort, grouping and selection ([[ADR-072 Multiple Windows]]).
The last-used filters are saved to `UserDefaults` (`ClinicTasksFilters`), and a new window starts from them.

## Consequences
- A fourth screen: `Screen.tasks`, a nav row, a notification, a menu item, a `ShortcutAction` and
  a `-ClinicScreenOnLaunch tasks` smoke key.
- The only screen with three panes. It needs a window about 1100 pt wide to show all three
  comfortably. Clinic's default is 1180.
- Not in v1:
  - An editable prompt template, and a Settings pane to hold it.
  - Issue types, sub-issues and Projects (v2) fields.
  - Hide, snooze and pin.
  - Tasks in ⌘K or the menu bar item.
  - Attaching an issue from inside the composer.

  All are in [[Backlog]].
