---
status: accepted (built 2026-09-17)
date: 2026-09-17
amends: "[[ADR-087 Pull Request Panel Is Status-First]] (the merge button offers only the repository's methods); [[ADR-116 The PR Panel Speaks Its Service's Visual Language]] (one allowed method drops the menu segment, as github.com does); [[ADR-163 A Pull Request Knows Its Stack]] (a stacked merge button counts what it lands, and auto-merge is hidden in a stack rather than disabled)"
tags: [adr, github, ui]
---
# ADR-164: The merge box offers what the repository allows

## Context
User (2026-09-17): *"It looks like the PR merge options don't respect the repository settings. For example I
almost always set squash-and-merge as the only option, but our panel should respect whatever setting is set.
Also, now that we've added stacked PR support from GH, we should make the "merge" button clearer when this is
the case"*.

The merge button led with the Settings method (*Merge with*, default squash) and its menu offered all three
methods on every repository. On a squash-only repository, picking *Create a merge commit* went to GitHub and
failed there. *Enable auto-merge* was offered in repositories that do not allow auto-merge too.

On a stacked pull request the button read *Squash and merge*, exactly as on a lone pull request, although it
merges every open layer under this one as well (ADR-163). Only the confirmation and a status line said so.

What GitHub exposes, checked live:
- GraphQL `Repository` has `mergeCommitAllowed`, `squashMergeAllowed`, `rebaseMergeAllowed`, `autoMergeAllowed`
  and `viewerDefaultMergeMethod`.
- A viewer with `READ` permission gets real answers, not nulls. On `cli/cli` (READ) all three methods came
  back allowed. On `r0adkll/clinic` (ADMIN) only squash did, with `viewerDefaultMergeMethod: SQUASH`.
- `gh pr view --json` has none of these. `gh repo view --json` has the three method flags but not
  `autoMergeAllowed`.
- GitHub's docs on stacks say stacks support all three methods, so a repository's own settings are the only
  limit on a stacked merge. The docs do not give the stacked merge button's wording.

## Options
- **Add the fields to the `gh pr view` read.** Not possible: it has no such fields.
- **`gh repo view --json`.** It lacks `autoMergeAllowed` and runs in a checkout, not against the PR's own
  repository. Rejected.
- **Add them to ADR-090's rendered-HTML query.** That query is per pull request and re-runs on its own rules.
  The settings are per repository and change rarely. Rejected.
- **A separate, non-fatal GraphQL read per repository.** Chosen.

For the stacked button:
- **Keep the title and add a count badge.** A bare "3" beside *Squash and merge* does not say three of what.
  Rejected.
- **Name the references** (*Squash and merge #14450–#14452*). Long, and a range reads as if the PRs had
  consecutive numbers. Rejected.
- **Count them in words** (*Squash and merge 3 pull requests*). Chosen.

## Decision
**Model (ClinicCore, pure, tested).** `RepositoryMergeOptions`:
- `methods` in GitHub's menu order (merge, squash, rebase). It is never empty: an empty answer is a bad read,
  and offering nothing would leave no way to merge.
- `autoMergeAllowed`.
- `viewerDefault`, dropped when it is not one of `methods`.
- `method(preferred:)` picks the button's lead method: the Settings choice if the repository allows it, else
  the repository's default for this viewer, else the first allowed method.
- `.unrestricted` (all methods, auto-merge allowed) stands in until the repository has answered, and for any
  host that is not GitHub.

**Reading.**
- `GitHubService.mergeOptions(_:)` runs `gh api graphql` with owner and repo only. It returns nil for GitLab.
- `PRStore` caches the options per `host/owner/name`, not per pull request.
- `PullRequestRefresh.needsMergeOptions` re-reads for an open PR when nothing was read yet or the read is older
  than `mergeOptionsTTL` (600 s). The ⟳ button always re-reads.
- A failed merge or auto-merge forgets the repository's read time, so the read that follows the error asks
  again. The likeliest error the panel could have prevented is a method the repository stopped allowing.
- A failed read keeps what was known and is logged.

**The merge box.**
- The split button offers only `methods`, and leads with `method(preferred:)`. With one method there is no
  menu segment, as on github.com.
- Enabling auto-merge uses the same lead method.
- `PullRequestStatus(pr:viewerLogin:stack:mergeOptions:)` gains `offersAutoMerge`. It is false in a stack and
  in a repository that does not allow auto-merge. There the *Enable auto-merge* button is not drawn at all,
  because GitHub has none to offer. `canAutoMerge` keeps its meaning, and its reason becomes *Auto-merge
  isn't allowed in this repository* where that applies. *Disable auto-merge* is still shown whenever auto-merge
  is on.
- `CodeHost.mergeTitle(_:count:)`: when a merge lands more than one pull request, the title counts them, e.g.
  *Squash and merge 3 pull requests*, *Rebase and merge 2 pull requests*, *Merge 2 pull requests* (GitLab:
  *Merge 2 merge requests*). The count is this PR plus `stack.landsWith`. A bottom layer, or one whose lower
  layers have all merged, keeps the plain title.
- The tooltip names what lands (*Merge #14450, #14451 and #14452 into trunk*). The confirmation's title uses
  the counted title.
- Settings' *Merge with* gains a footer: it applies where the repository allows it.

## Consequences
- The merge box stops offering a method GitHub would reject, and stops offering auto-merge where there is none.
- One more `gh api graphql` per repository on first load, then about one every ten minutes while one of its
  PRs is open.
- The button can change title once, when a repository's options land after the PR itself: for example from a
  Settings choice of *Merge pull request* to *Squash and merge*.
- Checked in a smoke instance (`~/Library/Caches/clinic-mrg`, deleted, defaults restored):
  - `cli/cli` #14452, layer 3 of 7, all methods allowed: *Squash and merge 3 pull requests* with the menu
    caret, no auto-merge button, disabled because #14450 below conflicts.
  - `r0adkll/upload-google-play` #288, squash only and auto-merge off: a plain *Squash and merge* with no
    caret and no auto-merge button.
- Not driven: opening the method menu, or a merge after the repository's settings changed.

## Not now
- **Merge queue.** A repository that requires a merge queue still gets GitHub's error, not *Merge when ready*.
- **Branch protection** (required reviews and checks) is still read only through `mergeStateStatus`.
