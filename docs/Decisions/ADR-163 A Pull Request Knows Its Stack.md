---
status: accepted (built 2026-09-17)
date: 2026-09-17
amends: "[[ADR-087 Pull Request Panel Is Status-First]] (a stack adds lines and can block the merge); [[ADR-127 The PR Panel Refreshes On Events Not On A Timer]] (a third read, the stack, on its own rule); [[ADR-129 A Merge In Flight Says So]] (a stacked merge is asynchronous and is polled to its end)"
tags: [adr, github, ui]
---
# ADR-163: A pull request knows its stack

## Context
User (2026-09-17): *"Is it possible to support Githubs new PR Stacks feature in our UI?"*, then *"Lets do it"*.

GitHub's stacked pull requests went into public preview on 2026-07-30. A stack is an ordered chain of pull
requests: position 1 targets the stack's base (the trunk), and each one above targets the branch of the one
below, so each shows only its own layer's diff. The rules that matter to a client:

- **Merging is bottom-up.** Merging layer *n* merges every unmerged layer under it in the same operation. A
  mid-stack pull request cannot merge alone. What lies above is rebased and retargeted onto the stack's base.
- **The legacy merge cannot merge a stack.** *"A stack cannot be merged with the legacy synchronous merge
  endpoints or mutations."* `gh pr merge` (2.63 here) uses the `mergePullRequest` mutation. A stacked merge
  has to go through `PUT /repos/{o}/{r}/pulls/{n}/merge-async`, which answers 202 with a `uuid` (or 409 with
  the existing one, or 200 when already merged or enqueued). Then `GET …/merge-async/{uuid}` is polled until
  `status` leaves `pending` for `merged`, `enqueued` or `failed`. The endpoint is in the default API version
  (2022-11-28), so `gh api` needs no version header.
- **Auto-merge is not supported** for stacked pull requests.
- **Reading is GraphQL.** `PullRequest.stack` (`number`, `size`, `baseRefName`, `entries { position
  pullRequest }`) and `PullRequest.stackEntry { position }`, both null outside a stack. There are no
  mutations. Creating, extending and dissolving go through the REST Stacks API or the `gh stack` extension.
  `gh pr view --json` has no stack field.

Checked live against `cli/cli`'s open seven-layer stack #14457 (PRs #14450–#14456) and `github/gh-stack`'s
merged stack #476. The query above returned the entries in position order, with a lower layer's
`mergeable`, `reviewDecision` and head-commit `statusCheckRollup.state` in the same call. A schema error
(a field the server lacks) fails the *whole* query with `undefinedField`, exit 1.

Before this, Clinic had no idea of a stack. `PullRequest` carried `baseRefName` / `headRefName` for wording
only, a session's pull requests were ranked by worst status and never ordered, and the merge box would
have offered a merge that GitHub rejects on every stacked pull request.

## Options
- **Read the stack from `gh stack view --json`.** It needs an extension installed and a checkout of the
  stack, and describes the local stack, not GitHub's. Rejected.
- **Add `stack` to ADR-090's rendered-HTML query.** One call fewer, but a host without the field (an
  Enterprise Server release from before stacks) would fail the query and lose the rendered bodies with it.
  Rejected.
- **Infer a stack from base and head names across a session's PRs.** Guesswork that GitHub now answers
  directly. Rejected.
- **A separate, non-fatal GraphQL read of the stack, and the async endpoint for a stacked merge.** Chosen.

## Decision
**Model (ClinicCore, pure, tested).**
- `PullRequestStack`: `number`, `size`, `baseRefName`, the viewed PR's `position`, and `entries` in position
  order. Each `Entry` has `position`, a `PullRequestRef`, `title`, `state`, `isDraft`, `headRefName`,
  `mergeable`, `reviewDecision` and a `checks` rollup (`passing` / `failing` / `pending` / `none`).
- `PullRequestStack.parse` returns nil for a null `stack`.
- `Entry.mark` builds a `PullRequestMark` from those fields, so a layer is drawn with the service glyph and
  the attention dot every other PR wears.
- Derived lists: `below`, `above`, and `landsWith`, the unmerged layers under the viewed PR that a merge of
  it would take along.

**Reading.**
- `GitHubService.stack(_:)` runs `gh api graphql` with its own query.
- Only for GitHub hosts. An `undefinedField` error marks the host as stackless for the rest of the launch,
  so an old Enterprise server is asked once, not every read.
- A failed stack read never blanks a pull request that loaded.
- `PRStore` keeps stacks per ref beside the pull requests.
- `PullRequestRefresh.needsStack(fresh:cached:stackFetchedAt:)` decides when to read it:
  - nothing cached;
  - the base branch moved (a lower layer merged and GitHub retargeted this one, which no local ref event
    reports);
  - the state changed;
  - the stack read is older than `stackTTL` (240 s) and the PR is open.
- A fast read over a running build does not pay for it.

**The merge box** (`PullRequestStatus.init(pr:viewerLogin:stack:)`).
- A pinned neutral line under Draft: *Layer 3 of 7 in a stack onto trunk*. Its detail names what a merge
  takes along (*Merging also lands #14450 and #14451*), or *Bottom of the stack* at position 1.
- A lower layer that is a draft or conflicting adds a blocking line naming it and turns `canMerge` off,
  with that reason. A lower layer's failing checks add a blocking line, and changes requested on a lower
  layer adds one too. Neither disables the button, the same as those facts on the PR itself (ADR-087).
- `canAutoMerge` is false in an open stack, and its reason is *Auto-merge isn't available for stacked pull
  requests*. The auto-merge button is disabled with that help text.
- The merge confirmation names the stack's base, not the PR's own base branch, and lists the layers it
  lands.
- The merge itself goes through `GitHubService.mergeStacked`: `merge-async` with the method and the head SHA
  the reader saw, then the result polled every 2 s for up to 3 minutes.
  - A 409's existing `uuid` is followed, not reported as an error.
  - `failed` throws its `message`.
  - `enqueued` counts as done.
  - The button keeps ADR-129's *Squashing…* for the whole span.
  - After it lands, every layer's cached read is refreshed, because each of them changed.
- An unstacked pull request still merges with `gh pr merge`, so Enterprise and every existing path are
  untouched.

**The stack map** (PR panel, between the header and the merge box).
- A bordered box headed *Stack 3 of 7*, with its rows drawn top of the stack first, as GitHub draws it, and
  a footer row *onto* the base branch's pill.
- Each row: the position, the layer's glyph with its attention dot, its reference and its title. The head
  branch and the mark's summary are in the tooltip. The viewed PR is washed, barred and labelled *This PR*,
  and a click on it does nothing.
- Clicking another layer opens that layer's PR pane in the same tab, reusing one already open.
- It starts expanded for four layers or fewer and collapsed above that. Collapsed, it shows the header
  and the viewed layer's neighbours.
- An open PR pane is polled whether or not the PR is in the session's list, so a layer opened from the map
  stays current like any other pane.

**Order.** Wherever a session lists its PRs (footer chips, card rows), PRs in the same stack are sorted by
position, and the first one of a stack keeps its place.

## Consequences
- The merge button stops offering a merge GitHub would reject on a stacked pull request, and says what a
  stacked merge will do before it does it.
- One more `gh api graphql` per pull request on first load, then about one every four minutes while it is
  open. Nothing extra on a 15 s poll.
- `PullRequestStatus` gains a `stack` argument (default nil) and `canAutoMerge` / `autoMergeBlockedReason`.
  Every existing caller and test keeps its meaning.
- Checked in a smoke instance against `cli/cli`'s live stack, from a session linking #14452 and #14450:
  - On layer 1, the map was collapsed to layers 1–2 with *Show all 7*, the status read *Layer 1 of 7…
    Bottom of the stack*, and the footer and card listed #14450 before #14452, though #14452 was linked
    first.
  - On layer 3, the map showed layers 2–4, the status read *Merging also lands #14450 and #14451*, and
    *#14450 below has conflicts* appeared as a blocking line with both merge buttons disabled.
- Not verified by merging a real stack: the argv, the response parsing and the polling are unit-tested. The
  first real stacked merge through Clinic is the end-to-end test. Clicking a layer on the map to open its
  pane was not driven either.

## Not now
- **Changing a stack** (create, add a layer, restack, unstack). These would be session actions that ask
  Claude to run `gh stack …`, the same shape as the existing prompts. Clinic will not call the Stacks API
  itself until there is a reason to.
- **The diff panel's branch scope** still compares with the default branch ([[ADR-080 Diff Panel]]). For a
  stacked branch it should compare with the layer below, or every layer's diff contains the layers under it.
- **A stack position on the sidebar mark** ("3/7").
- **Merge queue choice.** `merge_action` is left at `default`.
