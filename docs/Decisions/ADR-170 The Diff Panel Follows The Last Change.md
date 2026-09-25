---
status: accepted (built 2026-09-24)
date: 2026-09-24
amends: "[[ADR-080 Diff Panel]] (the Turn scope's default, the Branch scope on the default branch, how snapshots are serialised, where alternates point)"
tags: [adr, git, diff, panel, snapshots]
---
# ADR-170: The Diff panel follows the last change, and snapshots stop racing

## Context
User (2026-09-24): *"The "Diff" panel doesn't seem to work very well at all. I can almost never see the diff
for turns (or turns are not captured accurately in terms of actual code changes). Any of the other views also
don't reliably show diffs and make it hard to inspect what is going on."*

Read against the recorded snapshots for this repo (58 sessions, 294 turns) and the code, there were six faults.
Three of them were in the design, and three were bugs.

**How the design meets a trunk-based workflow.** Here a turn that writes code is usually followed by a turn
that says *commit and push*.
- **"Latest turn" meant the newest turn, whatever it did.** 136 of 294 turns changed nothing on disk. They were
  questions, and commit turns, since committing leaves the tree as it was. In 29 of 53 sessions the newest turn
  was one of these, so the panel's default view said *This turn changed nothing on disk*. To find the work, the
  reader had to guess which turn in the menu held it.
- **The menu could not help with that guess.** Per-turn `+n −n` loaded from `.onTapGesture` on a `Menu`. The
  menu's own mouse handling swallows that tap, so the counts never appeared.
- **Branch was always empty on `main`.** `merge-base(default, HEAD)` is `HEAD` there. Working tree is empty after
  every commit, which is correct but leaves one working view. That view was Session.

**Bugs.**
- **Snapshots raced for the scratch index.** `SnapshotStore` is an actor, but an actor is re-entrant at every
  `await`, and the git call is one. The diff panel also called `writeSnapshotTree` directly for the in-flight
  turn, Session and Working tree, on every file change. That is exactly when `UserPromptSubmit` and `Stop` take
  theirs. Two `git add -A` against one index fight over `index.lock`. Twenty concurrent pairs against this repo
  failed 20 times out of 20. The losing hook snapshot returned nil, so its turn was never opened, or was never
  closed until the next prompt. The retry path then deleted the index while the winner held it. A lock left by a
  git that was killed would have failed every snapshot from then on.
- **Worktrees pointed alternates at nothing.** In a linked worktree `.git` is a file, so `<root>/.git/objects`
  does not exist (`unable to normalize alternate object path`, logged for the Campfire worktrees). Every blob
  was copied into Clinic's store. `HEAD`'s tree could not be read against a snapshot, so Working tree → All
  failed with `fatal: bad object`.
- **The panel never heard about a snapshot.** It refreshed from an FSEvents watcher on the repository.
  Snapshots are written to Application Support, so a turn that opened or closed showed up only after some
  later edit happened to touch the repo. The panel also bound on `tab.pwd` alone. `/clear`, a fork and a
  continue re-key the tab ([[ADR-166 Session State Has More Than One Witness]]), and after that the panel went
  on reading the old session's turns.

## Decision
- **The Turn scope's default is *Latest changes*: the newest turn that changed something.** Turns are walked
  newest first. A closed turn whose trees match is skipped without running git. The in-flight turn counts as
  soon as its live diff has a file in it, and while it has none the panel stays on the previous turn with
  changes. The FSEvents refresh still follows the live turn, so its first write moves the panel onto it. Pinning a
  turn from the menu works as before. The empty state for the default now reads *No turn in this session has
  changed a file yet.*
- **The turn menu shows counts without being asked.** Numstat for every closed turn not yet counted is read
  whenever the turns are re-read, once per turn, since a closed turn's total never changes. A turn whose trees
  match is marked *no changes* without running git.
- **On the default branch, Branch shows the newest commit.** The first item of its menu reads *Latest commit*
  there, and *All commits on the branch* anywhere else. On a trunk-based repo that commit is what the last
  commit turn landed.
- **Every live snapshot goes through `SnapshotStore.liveTree`**, and the store runs these one at a time through
  a chain of tasks rather than relying on actor isolation. The diff panel's worktree diffs use
  `SnapshotStore.diff(from:toWorktreeOf:)`. `GitRepository.diff(from:toWorktree:)` is removed so that nothing
  can go round the chain. On a failed `add`, the retry removes a stale `index.lock` as well as the index: with
  the chain in place, nothing else can be holding it.
- **Alternates point at the real object store.** When `.git` is a file, `GitObjectScratch` follows its
  `gitdir:` line and that directory's `commondir`. That covers linked worktrees and submodules alike.
- **`SnapshotService.revision` is bumped after each recorded boundary**, and the panel reloads on it. It binds
  on the directory *and* the session id.

## Consequences
- Against the recorded history, the default view is blank in 4 of 53 sessions instead of 29. Those 4 are
  sessions that never changed a file.
- A turn lost to the race before this change stays lost, because the data is not there to rebuild it. Its
  changes still appear in the Session scope and in the turn after it, whose base was taken late.
- In a worktree, snapshot stores stop growing by a copy of every blob. Stores already bloated shrink only
  through the 14-day retention or through *Clear diff snapshots*.
- *Latest changes* can show a turn that is not the newest one. The header names the turn it shows, so the
  reader can see which turn that is.
- Counting turns for the menu costs one numstat per closed turn that changed something, read once.
