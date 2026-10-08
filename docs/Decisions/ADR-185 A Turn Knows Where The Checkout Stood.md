---
status: accepted (built 2026-10-06)
date: 2026-10-06
amends: "[[ADR-080 Diff Panel]] (what a turn records and what its diff is)"
tags: [adr, git, diff, snapshots, turns]
---
# ADR-185: A turn knows where the checkout stood

## Context
[[ADR-080 Diff Panel]] made a turn two trees, and argued that this made commits, amends and rebases inside
a turn irrelevant: *"the tree pair still states the net change."* That holds for what the turn commits. It
does not hold for what the turn checks out. Against the recorded snapshots (32 repositories, 107 sessions,
882 turns, read 2026-10-06):

- The largest turns were not work. *"Okay, PR stack merged. Lets make sure to switch back over to our top…"*
  is 264 files in 39 seconds. A branch switch, a pull and a rebase onto newer history all put every file
  they bring into the turn's diff. This is the plainest form of "displays completely different code".
- Two turns in this repository each carried 15 files another session wrote at the same time. A turn is two
  snapshots of one working tree, and nothing in a tree says who wrote a file.
- 39 of 783 consecutive turn pairs have a change between them that is in no turn.

## Options
1. **Label the turn and show everything.** Honest, and leaves the reader to find the work among 264 files.
2. **Hide every path whose change equals the commits' change.** Wrong for a turn that commits its own work:
   those paths also match the commits.
3. **Rebase the turn's start onto where the checkout landed.** Chosen.

## Decision
- **Turns and the session baseline record `HEAD`.** `TurnSnapshot` gains `baseCommit`, `baseBranch`,
  `headCommit` and `headBranch`; `SessionSnapshots` gains `baselineCommit` and `baselineBranch`. All are
  optional, so older files decode and resolve as before.
- **The checkout has moved when `HEAD` stands on history that was already there.** `landed` is the newest
  commit on `HEAD`'s first-parent line committed before the turn began. If it is the commit the turn started
  on, nothing moved: commits made since are the turn's own, and a turn that commits what it wrote leaves the
  tree as it was. If the branch is the same and `landed` is an ancestor of the start, the turn rewound — a
  reset, an amend — which is also its own doing. Otherwise the checkout moved (`CheckoutMove`).
- **A moved turn shows its own work.** The base becomes the tree the turn would have started from had the
  checkout already been at `landed`: that commit's tree, with every path that was uncommitted at the start
  taken from the start's snapshot. `GitRepository.tree(_:carrying:over:)` builds it in the scratch store
  from `read-tree` and `update-index --index-info`. `DiffResolution.pair` is that base against the head;
  `whole` keeps the snapshots' own pair.
- **The reader is told, and can see the rest.** The panel says the checkout moved, from where to where, and
  offers *Show everything* ([[ADR-187 The Diff Panel Says What It Compares]]). A turn's `+n −n` in the
  picker counts its own work, and a turn that only moved the checkout reads *only moved the checkout*.
  *Latest changes* does not follow such a turn.
- **Session does the same** from its baseline.
- **Another session's writing is flagged, not removed.** `SnapshotStore.sessionsOverlapping` counts the
  other sessions with a turn that changed something while this one ran, in the same repository. The panel
  says their changes are in here too. It cannot say which they are.

## Consequences
- Verified in Clinic Dev with a turn that checked out a branch three files ahead and edited one of them:
  the turn shows that file, `+1 −0`, diffed from the branch's version; *Show everything* shows all three.
- A commit another session made *during* the turn and this turn then pulled has a committer date after the
  turn began, so it counts as the turn's own. Telling those apart needs the reflog, which is not read.
- Turns recorded before today have no commits and keep their whole pair.
- A change made between two turns is still in neither. Session holds it.
- Each boundary costs two more git processes. Resolving a moved turn runs several more; the carried tree
  is built once and remembered by the trees it was built from.
