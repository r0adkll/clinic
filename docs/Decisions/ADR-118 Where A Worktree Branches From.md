---
status: accepted
date: 2026-09-10
supersedes: the "New branch from `<current branch>`" caption of ADR-083; amends ADR-098's rejected option
tags: [adr, ui, sessions, git, worktree]
---
# ADR-118: Where a worktree branches from

## Context
User (2026-09-10): *"We should be able to configure the base branch that worktrees should spawn
from, with a setting to change the default branch choice."*

Clinic starts worktree sessions with `claude -w [name]` ([[ADR-071 New Session Screen]]) and has
never chosen the base. [[ADR-083 Worktree Control]]'s caption told the user *"New branch from
`<current branch>`"*. **That was wrong.** Facts, each checked by hand on 2026-09-10 against
`claude` 2.1.268 in a scratch repository whose `HEAD` was on `feature`, two commits past `main`:

- **`-w` branches from the remote's default branch.** The CLI's `worktree.baseRef` setting
  (documented under *Choose the base branch*) is `"fresh"` by default: `origin/HEAD`, fetched when
  more than 24 hours old, falling back to `HEAD` without a remote. The worktree came out on `main`.
  - `"head"` branches from the launch directory's `HEAD`; that worktree came out on `feature`.
  - **The setting takes no branch name.** The docs send you to `git worktree add` for that.
- **The branch is `worktree-<name>`**, not `<name>`. ADR-114's "it becomes the CLI's worktree and
  branch name" is loose in the same way: the branch is `worktree-issue-<n>-<slug>`.
- **A second `--settings` flag replaces the first; it does not merge.** Passing
  `--settings hooks.json --settings '{"worktree":…}'` kept the base and dropped the hooks.
- **`-w <name>` adopts a directory that already exists** at `.claude/worktrees/<name>`, at its own
  tip, under either `baseRef`. It opened a worktree made with `git worktree add … develop` on
  `develop`.
- **The CLI copies `.worktreeinclude` files only into worktrees it creates**, not into one it adopts.
  With `.env` listed and ignored, the adopted worktree had no `.env`; a CLI-created one beside it did.

[[ADR-098 WorktreeCreate Is Not Ours]] rejected making `clinic-hook` run `git worktree add`, on the
grounds that it "buys nothing over what the CLI already does". A named base is the thing it buys.

## Decision
### Three bases
`WorktreeBase` (ClinicCore) is one of:

| Base | Menu label | How it launches |
|---|---|---|
| `.defaultBranch` | Default Branch — `main` | `-w [name]` with `worktree.baseRef: "fresh"` |
| `.currentBranch` | Current Branch — `feature` | `-w [name]` with `worktree.baseRef: "head"` |
| `.branch(ref)` | any local or remote-tracking branch | Clinic creates it, then `-w <name>` with `"head"` |

- **The base always travels explicitly.** A `baseRef` in the user's own `~/.claude/settings.json`
  cannot change what the composer said would happen.
- **It rides in Clinic's hooks file**, because a second `--settings` would drop the hooks.
  `HookService` writes `hooks.json` (resumes, forks, continue: no `worktree` key) plus two twins,
  `hooks-worktree-fresh.json` and `hooks-worktree-head.json`, and `newSession` picks the twin for a
  worktree launch.
- **A named branch is created by the app, not the helper**, which stays the dumb forwarder ADR-098
  wanted. `TabStore.prepareWorktree` does it, over `GitRepository.createWorktree(_ plan:)`:
  - `git worktree add --no-track -b worktree-<name> <repo>/.claude/worktrees/<name> <ref>`, the
    CLI's own spelling and place, so every later step treats it as one of its own;
  - `--no-track` because a branch started from `origin/develop` would otherwise track it, and a
    push would aim at someone else's branch;
  - then the `.worktreeinclude` copy the CLI would have made: files that match the include file
    **and** are gitignored (`ls-files --others --ignored --exclude-from`, then `check-ignore`);
  - `"head"` on the launch, because the CLI documents that under `"head"` a reused worktree is never
    reset to the default branch.
- **An empty name** under `.branch` becomes `<slug of the ref>-<4 random chars>`
  (`origin-release-2-0-k3x9`); the CLI can't name a directory it didn't create. Under the other two
  bases the CLI still names it.
- **A name whose directory already exists is reopened, not created**, as `-w` would. The row says
  *"Reopens the existing `.claude/worktrees/<name>`"* rather than implying the base applies.
- **Failure stays in the composer.** Send spins while git runs; git's own sentence
  (*"a branch named 'worktree-x' already exists"*) appears under the branch field, and nothing
  launches. The immediate paths (⌘↩ from Tasks, New Session in Worktree) show it in an alert.

### Choosing it
- **Composer:** the worktree row's caption is now *"New branch from [base ▾]"*. The menu, in order:
  1. Default Branch — `<name>`
  2. Current Branch — `<name>`
  3. Local Branches: the 20 most recently committed, excluding those two
  4. Remote Branches ▸: the 50 most recently committed with no local twin
  5. **Make This the Default for `<project>`** / **Use the Settings Default**

  A per-draft pick doesn't stick: one session from a colleague's branch shouldn't change the next
  one. *Make This the Default* writes `ClinicState.worktreeBaseByProject[path]`, and the row says
  *"· this project's default"* while the pick matches it.
- **Header pill:** `<base> → <name>` while the toggle is on (ADR-083 showed the current branch).
- **Settings → Sessions → New worktrees branch from:** *The default branch* (the default, matching
  the CLI) or *The current branch*, stored as `ClinicWorktreeBase`. A named branch isn't offered
  there; branch names belong to one repository.
- **Precedence:** the draft's pick, then the project's default, then Settings.

## Consequences
- ClinicCore gains `Git/Worktrees.swift`:
  - `WorktreeBase`, a `RawRepresentable` `Codable` (`default`, `current`, `branch:<ref>`), so
    `@AppStorage` and `state.json` share one spelling;
  - `WorktreePlan`, pure and tested;
  - `GitBranches` and `GitRepository.branches()`, `createWorktree`, `copyWorktreeIncludes`.
  - `HookSettings.json` takes an optional `worktreeBaseRef`.
- `NewSessionDraft` gains `worktreeBase`, `isStarting` and `startError`. `TabStore.newSession` takes
  an optional `worktreeBase`, and launching moves to a private `launchNewSession`.
- New smoke key (ADR-038): `-ClinicDraftWorktreeBaseOnLaunch default|current|branch:<ref>`.
- Clinic must be restarted for the twin settings files to exist (`HookService` writes them at
  launch, like `hooks.json`, ADR-098).
- Automations ([[ADR-095 Automations]]) still launch `--bg -w` with plain `hooks.json`, so they take
  the CLI's default or the user's own `baseRef`. Giving an automation a base is not in this change.
- If the CLI later accepts a branch name for `baseRef`, `.branch` should move onto it and Clinic
  should stop creating worktrees itself.
