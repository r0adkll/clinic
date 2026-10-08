---
status: accepted (built 2026-10-06)
date: 2026-10-06
amends: "[[ADR-080 Diff Panel]] (how a scope is loaded and refreshed), [[ADR-170 The Diff Panel Follows The Last Change]] (when the panel reloads)"
tags: [adr, git, diff, panel, architecture]
---
# ADR-183: The Diff panel has one loader, and a scope is two trees

## Context
User (2026-10-06): *"The diff viewer is still not working well. Sometimes the views display completely
different code or doesn't feel very intuitive at all."* Then, after a review: *"We should only take existing
ADRs as input but should aim to improve this experience and write new ADRs."*

The review found three ways the panel showed a diff that was not the one its header named. All three were in
how it refreshed, none in how it drew.

- **The file watcher never came back.** `SidePanel.syncWatchers` stops the watcher whenever the Diff pane is
  not the one on screen. `DiffPanelModel.bind` runs again when it returns, but returned early for an unchanged
  repository, before the only line that built a watcher. After the first pane switch or the first time the
  panel was hidden, the panel refreshed only at a turn boundary. A running turn, Session and Working tree all
  showed what had been on disk when the reader last arrived.
- **Loads were not ordered.** `reload()` awaited `loadDiff()` directly and was called from three places (the
  view's `.task`, the snapshot `revision`, the watcher). A change of scope, turn, side or commit started a
  fourth load in its own task and cancelled only earlier loads of that kind. Each read `scope` when it began
  and wrote `files` when it finished. A slow load for the scope the reader had just left could finish last.
- **Branch did not follow a commit.** A file event re-read the commit list but skipped the diff unless the
  scope was "headed by the working tree". The header then named the new commit over the previous commit's diff.

Each scope also had its own way to a diff: `diff-tree` for turns and Session, `git diff` twice plus one
`git diff --no-index` per untracked file for Unstaged, `git diff A...B` for a branch, `git show` for a commit.
Nothing in the model could ask whether two refreshes had produced the same thing.

## Decision
- **A scope resolves to two trees.** `DiffTarget` (ClinicCore) names what is wanted: a turn, the session,
  uncommitted work by side, a branch from its base, a commit. `SnapshotStore.resolve` turns it into a
  `DiffResolution` holding a `DiffPair` (repository, base tree, head tree). Every scope is then one
  `git diff-tree`.
  - *Staged* and *Unstaged* need the index as a tree. `git write-tree` on the user's index would add tree
    objects to their repository, so `GitRepository.indexTree` copies the index into the scratch store and
    writes the tree there. The blobs it names are already in the repository, reached through alternates.
    Staged is `HEAD` to that tree, Unstaged is that tree to the working tree. Untracked files come along
    because the working tree's snapshot already holds them.
  - A commit diffs against its first parent's tree, or the empty tree at a root. A repository with no
    commits diffs against the empty tree.
- **The pair is the identity of what is on screen.** Identical trees differ in nothing, so an empty scope is
  known without running a diff. The same pair as last time is not read or drawn again. The store keeps the
  last eight parsed diffs and every `+n −n` it has counted, keyed by pair.
- **One loop serves every refresh.** `DiffPanelModel.request` takes what is wanted (the diff, or the diff
  and the metadata around it) and `drain` serves requests one at a time. Requests that arrive while it runs
  are folded into one more pass. Each change of what the reader asked for bumps `selectionEpoch`. A pass
  reads it when it starts and checks it before it writes; a result for an older selection is dropped.
- **The watcher belongs to the model.** `bind` starts it whenever there is a repository and none is running,
  so coming back to the pane starts it again. A second `bind` that begins while the first is asking git wins.
- **Every file event refreshes every scope.** The checkout is read once per pass as a `WorkingState` (tree,
  commit, branch) and handed to each `resolve`. When it equals the last one read, the turns have not changed
  and the selection is the same, the pass stops there. Staged and Unstaged are excepted, because `git add`
  moves the index and neither the tree nor `HEAD`. A change of `HEAD` re-reads the commits and branch base.
- **A refresh replaces nothing until it has something.** The header shows a spinner only while a selection
  the reader made is on its way. A refresh that fails leaves the diff on screen under a line saying so.

## Consequences
- `GitRepository.diffAll`, `diff(branchFrom:)` and `diff(commit:)` stay as tested primitives. The tests
  check that the tree pairs produce the same diffs they do.
- Reading the index as a tree does not work for a split index or an index with unmerged entries. Staged
  and Unstaged then report the error; *All changes* is unaffected.
- A pass over a checkout that has not moved costs one snapshot and a read of `HEAD`, and stops there.
- `DiffPanelModel` is still in the app target and still has no tests of its own. What moved into
  ClinicCore — which trees a scope means — is tested there (`DiffTargetTests`).
