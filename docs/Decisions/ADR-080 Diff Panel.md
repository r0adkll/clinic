---
status: accepted
date: 2026-09-08
supersedes: "[[ADR-052 Git Page]]"
tags: [adr, git, diff, ui, panel, milestone-5]
---
# ADR-080: The git page becomes a Diff panel

## Context
[[ADR-052 Git Page]] shipped a git client: status → stage → commit, with a diff as the detail view
of the selected file. User (2026-09-08): *"I don't think a generic GIT interface is very useful in
the context of this project. I'm thinking more of a 'Diff' panel where we can scroll through the
diffs of different contexts related to our current session — the last/current turn, unstaged/staged
changes, the branch by commit."*

That is the right frame. A git client is a solved commodity and the terminal is two keystrokes away;
what no git client can answer is **"what did this agent just change?"** Clinic already owns the
session model, the turn state machine ([[ADR-026 Session State Machine]]) and the hook stream
([[ADR-027 Installed Hook Set]]) needed to answer it, and has never used any of them in the git page.

The obstacle is that a *turn* is not a git object. There is no commit at a turn boundary, the working
tree moves under you, and the agent may commit, amend or rebase mid-turn. Answering "what changed
during this turn" requires capturing the tree at each boundary — and doing so without writing to the
user's repository, which is the same principle [[ADR-018 Claude Data Write Policy]] applies to
`~/.claude`.

## Options
Considered for capturing turn boundaries:
1. **`PostToolUse` on Edit/Write**, reconstructing changes from tool inputs. Rejected: ADR-027
   deliberately does not install per-tool hooks (high frequency, no state value), and it is blind to
   everything a `Bash` tool call changes — which is most of what matters.
2. **`git stash create` / a `refs/clinic/*` ref per turn.** Works, but writes objects *and* refs into
   the user's repo, shows up in `git log --all` and `gc` output, and a stash entry is a merge commit
   that has to be cleaned up. Rejected on the write policy.
3. **A shadow clone or a file-copy snapshot** under Application Support. Rejected: O(repo) per turn,
   and it throws away git's own dedup and diff machinery.
4. **A tree written to a Clinic-owned object directory, reading the repo through alternates.** Chosen.

Measured on the Clinic repo (108 tracked files) before deciding: 45 ms cold, 22 ms with a warm index,
zero bytes written into `.git`.

## Decision

### Turn snapshots
A snapshot is a **git tree object written outside the repository**:

```
GIT_OBJECT_DIRECTORY=<app support>/snapshots/<sha of repo root>/objects
GIT_ALTERNATE_OBJECT_DIRECTORIES=<repo>/.git/objects        # absolute; relative paths fail
GIT_INDEX_FILE=<app support>/snapshots/<sha of repo root>/index
  git read-tree HEAD && git add -A . && git write-tree
```

Every new object lands in Clinic's directory; the repo's object store is only ever *read*, through
alternates. No refs, no stash, the user's index untouched. `git add -A` honours `.gitignore` and
includes untracked files, so a snapshot is exactly "what is on disk that git would care about";
submodules record as gitlinks and are not recursed. Diffing two snapshots is `git diff-tree -p T1 T2`,
whose output feeds the existing `UnifiedDiff` parser unchanged — so commits, amends and rebases inside
a turn are irrelevant, the tree pair still states the net change.

`TurnSnapshot` (ClinicCore, persisted per session as JSON beside the object dir):
`sessionId`, `repoRoot`, `index` (1-based within the session), `prompt` (first line), `startedAt`,
`endedAt`, `baseTree`, `headTree` (nil while the turn is in flight).

`SnapshotStore` is a single actor keyed by repo root. Snapshots for one repo are **serialised** —
the index file is shared state and concurrent `git add -A` would corrupt it.

### No new hooks
The events ADR-027 already installs are sufficient: `SessionStart` → session baseline;
`UserPromptSubmit` → open a turn with `baseTree`; `Stop` / `StopFailure` → close it with `headTree`;
`SessionEnd` → close any turn still open. `HookEvent` gains `prompt`, so a turn is labelled without
parsing the transcript. Hooks are already `async: true`, so snapshotting never blocks the agent.

Three boundary rules:
- **`SessionStart` with `source: compact | clear` does not reset the session baseline** — only
  `startup` and `resume` do. **Session scope therefore means "since this attach"**: a week-old
  resumed session's aggregate is noise, and its individual turns are still listed.
- **A change of repo root mid-session starts a new lineage.** Turns carry their `repoRoot` and the
  panel lists only those matching the pane's repo, so a `-w` worktree or a `cd` elsewhere cannot
  produce a diff between unrelated trees.
- **Snapshots begin the day this ships.** Turns taken before it, and sessions Clinic does not own
  ([[ADR-047 No Global Hook]]), have none; the scope shows an empty state saying so.

### Scopes
The pane is one diff reader; the picker chooses which pair of trees it renders.

| Scope | Base → Head | Secondary control |
|---|---|---|
| **Turn** | turn `baseTree` → `headTree` (live worktree while in flight) | menu of recent turns: prompt's first line, `+n −n`, relative time; the in-flight turn pinned at the top |
| **Session** | attach baseline → live worktree | — |
| **Working tree** | HEAD → index / worktree | Unstaged / Staged / All |
| **Branch** | `merge-base(default, HEAD)` → HEAD | commit list, or *All commits* for the aggregate |

The in-flight turn and the two worktree-headed scopes refresh off the `FSEventsWatcher` ADR-052
already runs, debounced as before.

### Read-only
The panel shows diffs and nothing else. Stage, unstage, discard, the per-hunk buttons and the commit
box are all removed — supersedes ADR-052's staging decisions. Mutating git stays where it already
is: the terminal, and the project menu's Pull / Checkout ([[ADR-065 Repo Upkeep]]). `GitRepository`
loses `apply` (per-hunk patching had no other caller) and keeps `stage` / `unstage` / `discard` /
`commit` as tested primitives — they are what the fixtures in `GitTests` are built from, and a
file-level Discard may return as a context-menu item.

### Layout
- **Header**: scope picker, the scope's secondary control, `+n −n` totals. The branch and its
  ahead/behind sit in the Branch scope's own control rather than a header field of their own: at
  380 pt the panel cannot spare a third row, and the pane chip and the footer both already name the
  branch.
- **Rail**: one row of horizontally scrolling file chips (basename + counts) under the header,
  tracking the scroll position via `onScrollTargetVisibilityChange`; a trailing chevron opens a
  popover listing full paths for jumping. It is the file list and the jump target in one row, which
  is what a 380 pt panel can afford.
- **Body**: a `LazyVStack` of collapsible file sections — the whole scope in one continuous scroll,
  read like a PR review, rather than ADR-052's list-then-detail.
- **The diff is flattened into one row per rendered line** (`DiffPage` in ClinicCore), so a single
  `LazyVStack` in a single `ScrollView([.vertical, .horizontal])` virtualises down to the line.
  Sections keep the file headers pinned. **Superseded the per-file horizontal scroll below**: a
  non-lazy stack inside a nested scroll view stopped virtualisation at the file boundary, so one
  300-line file near the viewport built 300 rows at once and a 40-file diff was unscrollable.
- **Paging is a line budget, not a file count**, default 20,000 rows, extended by a "Show more"
  row and by clicking a rail chip for a file the page has not reached. Files come in whole — a
  half-rendered file reads as a truncated file, not as a page break — and the page is always a
  prefix, so "show more" never reshuffles what is already on screen. The first file always comes in
  whatever its size. Building rows is cheap (72k rows in ~26 ms, measured); the cost that justifies
  the budget is highlighting.
- **Collapsing changes what a page costs, never which files it holds.** The budget decides the page
  size *when the reader asks for more*, not on every rebuild — so collapsing frees budget for the
  next "Show more" rather than pulling unrelated files onto the screen behind it. The earlier rule
  (collapse frees budget immediately) meant collapsing 12 files silently loaded 12 more and
  re-highlighted all of them: 15 s of pegged CPU for what should be free.
- **Highlighting is incremental and genuinely cancellable.** Row ids are stable for the life of a
  diff, so results accumulate per file and a collapse or a page extension only highlights what is
  new. The highlighter checks cancellation per file, not merely on return: a superseded pass that
  runs to completion still holds its actor, and a dozen queued behind each other were what turned
  1.5 s into 15 s. Rows are cached per file (`DiffPage.RowCache`) so a rebuild is array assembly.
- **Views take the model by reference, never the page by value.** `DiffPage` and the highlight
  dictionary are `Equatable` and enormous; handing them to a view as parameters makes SwiftUI
  deep-compare tens of thousands of rows and strings on every update. The rail takes
  `DiffFileSummary` for the same reason — it used to take the whole `[UnifiedDiffFile]`.
- **The content width is arithmetic, not measurement**: the font is monospaced, so
  `longest line × advance` sizes the shared horizontal axis. No per-row measuring pass, and the
  width cannot jump as lazy rows come and go.
- **Syntax highlighting** reuses the tree-sitter stack the editor panel already depends on
  ([[ADR-057 Editor Panel]], [[ADR-058 Third-Party Packages Allowed]]) and the same palette, so a
  file reads alike in both panes. Each hunk is parsed as two snippets — the new side (context plus
  additions) and the old side (context plus deletions) — rather than fetching and parsing both whole
  files: tree-sitter is error tolerant, so a fragment still yields the captures that matter for
  reading a diff. Captures are bucketed into lines in one ordered pass; filtering the capture list
  per line is O(lines × captures) and costs tens of millions of comparisons on a large file.
  Highlighting runs off the main actor *after* the plain text is on screen, so it never delays the
  diff. Whole-file context, which would fix a hunk that opens inside a string or comment, is the
  obvious later upgrade.
- ~~**Each file section scrolls horizontally on its own.**~~ `DiffView`'s `.fixedSize(horizontal: true)`
  measures every line to size the stack; across forty files that is unaffordable, and per-file
  scrolling bounds it. The cost is that horizontal scroll is not synced between files. Files over
  500 changed lines start collapsed. Inside that horizontal scroll a row's `maxWidth: .infinity`
  resolves to the *content* width, so each file's stack carries a `minWidth` of the measured
  viewport — without it the row highlights stop at the longest line instead of spanning the panel,
  and `fixedSize` on the stack defeats the fix by making it ignore the proposal entirely.
- `DiffView` is generalised from `UnifiedDiffFile` to `[UnifiedDiffFile]`; the PR page's Files tab
  ([[ADR-053 Pull Request Page]]) adopts the same view.

### Pane identity
`SidePanel.Kind.git` becomes `.diff`, titled **Diff** ([[ADR-079 Panel Tabs]]). ⌘⇧G keeps its chord
and its place in the shortcut editor's Panel section, so existing overrides survive
([[ADR-073 Rebindable Shortcuts]]).

### Retention
A repo's snapshot directory is deleted when no live session references it and it has not been touched
for 14 days. Preferences → Diagnostics gains the on-disk size and a **Clear diff snapshots** button.
No object-level GC: `git prune` cannot usefully be pointed at an alternate object directory.

### Not now
Split view, word-level emphasis, image diffs, line-level staging, vim keys, a "reviewed" mark on
turns you have already read, and a link from a turn to its place in Replay ([[ADR-059 Replay and
Session Details]]).

## Consequences
- `show_diff` / `annotate_diff` / `highlight_diff`, deferred in [[ADR-056 Session MCP Tools]] for want
  of a page to address, now have one: a scope is a nameable target.
- A blob that existed only in the repo's loose objects and is later pruned by the user's own `git gc`
  can orphan an old snapshot. The diff fails; the panel reports it and offers the next scope. Blobs
  that were only ever in the worktree are safe — they were copied into Clinic's object directory.
- The object directory grows with one blob per file per turn that changed it. Bounded by retention,
  surfaced in Diagnostics.
- Turn snapshots are a general capability, not a panel feature: "what did this turn change" is now
  answerable anywhere in the app — a sidebar badge, a notification body, an agent tool.
