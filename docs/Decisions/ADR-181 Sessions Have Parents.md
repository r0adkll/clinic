---
status: accepted
date: 2026-10-04
amends: "[[ADR-063 Session Lifecycle Controls]] (a fork remembers what it was forked from), [[ADR-077 Persistent Projects and Sidebar Polish]] and [[ADR-040 Sidebar Ordering and Row Visuals]] (a project's rows are a tree, ordered by subtree), [[ADR-156 Sessions Can Be Cards]] (the card's spawned-session line gives way to the row beneath it; `spawnedBy` becomes `parents`), [[ADR-059 Replay and Session Details]] (Details gains a Lineage section)"
tags: [adr, ui, sidebar, sessions]
---
# ADR-181: Sessions have parents

## Context
User (2026-10-04): *"if we fork a session, it should display as a child of the current session in the side
bar (not like subagents or other tasks, but like an indented session"*, and a session should be able to ask
for another session and get the result back ([[ADR-182 A Child Session Reports To Its Parent]]). The
decisions below were taken in four rounds of the grilling skill the same day.

What Clinic had:
- **Fork** ([[ADR-063 Session Lifecycle Controls]]) runs `claude --resume <id> --fork-session` in a new tab
  titled *Fork of …* and rebinds the tab when `SessionStart` reports the new id. Nothing records which
  session it came from, so the fork lands in the project as an unrelated row.
- **`start_session`** ([[ADR-056 Session MCP Tools]]) opens a sibling tab and writes `ClinicState.spawnedBy`
  (child → parent), which [[ADR-156 Sessions Can Be Cards]] shows as one line under the parent's card while
  the child's tab is open. A compact row shows nothing.
- The sidebar lists a project's sessions flat, newest activity first (`SessionStore.sessions(in:)`).

Probed before deciding, CLI 2.1.289: a forked session's transcript rewrites every copied record to the new
session id and holds **no reference to the parent**, no field of any name. The copied records do keep the
parent's record `uuid`s. The `SessionStart` payload for a fork says `source: fork` and nothing about where
from. So lineage is Clinic's record, written at the moment Clinic launches the child, exactly as `spawnedBy`
already was.

## Options
- **Nest everything with a known origin** — work-item sessions under their task, detached agents under the
  session that backgrounded them, a `/clear` under the session it cleared. Rejected: lineage means *this
  session came out of that one*. A `/clear` is the same conversation restarting and is already a re-key
  ([[ADR-166 Session State Has More Than One Witness]]); a task is not a session; a detached agent is the
  same session.
- **A cross-project child in its own project with a backlink**, or **in both places.** Rejected: the parent
  is where the user asked for the result, so it is where they will look; listing a session twice makes the
  sidebar lie about how many there are.
- **One level only** (grandchildren flattened under the top ancestor). Rejected: a session that spawns a
  worker which forks to try two approaches is plausible, and flattening hides which one did it.
- **Infer forks made outside Clinic** from the shared record uuids. Not now: it reads undocumented shapes
  for a small payoff, since Fork is in Clinic. Recorded here so the option is not lost.

## Decision
- **Two relationships, recorded by Clinic**: a **fork** (the Fork command, or `start_session(fork: true)`)
  and a **spawn** (`start_session`, or the New Child Session sheet of ADR-182). `ClinicState.parents`
  (child → `Parent { id, kind, since }`) replaces `spawnedBy`; an old `spawnedBy` entry decodes as a spawn.
  `TabStore.fork` writes the fork's parent when `SessionStart` rebinds the tab to the new id. An entry whose
  child transcript is gone is dropped on rescan, as before.
- **A child is an indented row under its parent**, in the parent's project, whatever directory the child
  runs in. The tree is as deep as the sessions made it. Each level indents by the card's text inset (the
  glyph column plus its gap), so a child's glyph sits under its parent's title, with a hairline down from
  the parent's glyph column as a card's children have.
- **A cross-project child says where it is**: the compact row's caption gains *· in ‹project›* and the
  card's where-line leads with the project name, only when the child's project is not the section's.
- **Ordering**: a subtree is placed by the newest activity anywhere in it; children are ordered among
  themselves the same way. The sidebar's promise that what is happening now is at the top holds through
  a parent that is idle while its child works. The *created* sort (ADR-040) keys the same way on creation.
- **A parent folds**: a chevron appears on hover at the row's trailing edge and stays while collapsed,
  with the number of sessions folded beside it. Collapsed parents persist in `ClinicState.collapsedSessions`.
  Folding is suspended while a filter is typed, as it is for projects. **A collapsed parent carries its
  subtree's status**: its glyph breathes orange if any folded descendant waits for the reader, and turns
  the working arc if one works while the parent itself rests. An expanded parent does not: the child row
  right under it says so itself. (ADR-156's rule that a waiting spawned session raises the parent's glyph
  now applies only while the subtree is folded.)
- **Filtering** keeps the tree: a child that matches shows under its parent, and the parent is drawn
  normally as context even when it does not match. Nothing flattens.
- **The kind glyph**: under the status glyph in the glyph column, a small secondary `arrow.branch`
  for a fork and `arrow.turn.down.right` for a spawn. Its help reads *Forked from ‹parent›* or *Started by
  ‹parent›*. No colour per kind ([[ADR-096 Session Status Indicators]], and the accent rule of ADR-111).
- **Archive takes the subtree**: archiving a parent archives every descendant (each open tab closed first
  through the usual confirmation), and one Undo restores the whole group. A child can be archived alone.
  A child whose parent is archived, hidden or missing shows at the root of its own project.
- **Favorites stay flat.** A favorited child is a plain row in Favorites; its kind glyph's help names
  the parent.
- **Cards drop their spawned-session child line.** The children zone is for things that are not sessions.
- **Go to Parent** joins a child row's context menu. **Details** gains a *Lineage* section: the parent
  (*Forked from* / *Started by*, a button that reveals it) and the children, each a button.
- **`SessionTree` (ClinicCore)** builds the rows: given a project's visible sessions, every visible session
  with a parent, the parent map, the sort, the folded set and a match set, it returns `[Row]` with depth,
  the number folded under a collapsed row, and whether the row is context for a match. Pure and tested.

## Consequences
- A session can appear in a project section whose directory is not its own. The project header's count
  includes it, since it counts rows.
- A fork started from a plain terminal, or one made before this ADR, has no parent and sits at the root.
- One `repeatForever` animation more only for a collapsed parent with a live descendant; expanded trees
  animate their children's rows as before.
- Verification is recorded in [[Log]] when the branch lands.
