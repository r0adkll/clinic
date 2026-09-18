---
status: accepted (built 2026-09-17)
date: 2026-09-17
amends: "[[ADR-065 Repo Upkeep]] (Git Pull's result is a sheet, not an alert of git's stdout)"
tags: [adr, git, ui]
---
# ADR-165: Git Pull says what arrived

## Context
User (2026-09-17): *"The git pull dialog leaves a-lot to be desired. This could use a UI/UX pass to improve it."*

ADR-065's *Git Pull* ran `git pull --ff-only` from the project menu. It showed nothing while git ran, which
can take seconds on a slow remote. Afterwards it opened a warning-style `NSAlert` titled *Git pull* holding
git's raw stdout (`Updating a..b / Fast-forward / file | 2 +-`), even when the pull had worked. A failure put
`GitError`'s description in the same alert, e.g. *git pull --ff-only exited with 128: fatal: Not possible to
fast-forward, aborting.*, and offered nothing to do next.

## Options
- **Keep the alert and tidy the text.** It stays modal with a warning icon on success, and still shows nothing
  while git runs. Rejected.
- **A notification card.** Fine for "pulled 3 commits", but a refusal needs room for a reason, a file list and
  next steps. Rejected.
- **A sheet that follows the pull from start to finish.** Chosen.

## Decision
**Model (ClinicCore, tested).**
- `GitRepository.pullReport(commitLimit:)` replaces `pull()`. It checks the branch and upstream first, so a
  detached HEAD or a branch without an upstream is refused without touching the network. It runs
  `git pull --ff-only --no-rebase`. `--no-rebase` stops a `pull.rebase` setting from turning the pull into a rebase.
- A pull returns a `GitPullReport`: branch, upstream, HEAD before and after, the new commits (newest first,
  capped at 50), their total count and a `DiffStat` of before..after.
- A refusal throws `GitPullError`, which holds a `GitPullFailure` read from git's C-locale stderr, plus
  git's own output. The failures are: detached HEAD, no upstream, upstream deleted on the remote, diverged,
  local changes (with the files), untracked files in the way (with the files), authentication, network and
  `other`. A diverged branch is given ahead/behind counts from `rev-list --left-right --count`.

**The sheet.** *Git Pull* opens `PullSheet` straight away:
- The header shows the project icon, a title that follows the outcome, and *project · branch ← upstream*.
- **Running**: a spinner and *Fetching from origin and fast-forwarding…*. Close stops watching, and git carries on.
- **Up to date**: *Already up to date*, *main already has everything on origin/main.*
- **Pulled**: *Pulled N commits*, the old…new SHAs, files and +/− totals, and a list of the commits
  (short SHA, subject, author, relative date) that scrolls past 240 pt. Any beyond 50 are counted as *and N earlier*.
- **Refused**: a headline in words (*main has diverged*, *Uncommitted changes are in the way*, *Its remote
  branch is gone*…), a sentence saying why and what to do, the files in the way, and a *Git output*
  disclosure. The disclosure opens by itself only for `other`, where git's words are the only explanation.
  Buttons: *Open Shell Here*, *Try Again*, *Close*. A deleted upstream also gets *Check Out main*, which
  checks out the default branch and pulls it.
- `-ClinicPullOnLaunch <path>` opens the sheet at launch for smoke runs (ADR-038).

## Consequences
- A successful pull no longer shows a warning alert. Every refusal names its cause, and most offer a next step.
- Three to five extra local git calls around the pull (branch, upstream, rev-parse, log, numstat), all cheap.
- The classifier depends on git's English wording. Unrecognised text falls back to `other`, which shows
  git's output, so a new git message is no worse off than before.
- Checked in a smoke instance (`~/Library/Caches/clinic-pl`, deleted, defaults domain diffed unchanged)
  against scratch repos: up to date, 4 commits pulled, diverged 1/4, a dirty `a.txt`, and a deleted
  `feature/…` upstream. All rendered as described. Not driven: the buttons.
