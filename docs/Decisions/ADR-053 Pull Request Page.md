---
status: accepted
date: 2026-09-07
tags: [adr, github, ui, milestone-3]
---
# ADR-053: Pull request page and marks

## Context
Second page of milestone 3. Collins detects a session's PRs from transcript `pr-link` records and first-prompt URLs, shows an aggregated mark on the sidebar row and chips in the footer, and opens a native PR page (body, checks, timeline, files) with actions, all through the GitHub CLI. Verified locally: transcripts write `{"type":"pr-link","prNumber","prUrl","prRepository","timestamp"}`; `gh` is authenticated and exposes `statusCheckRollup`, `comments`, `reviews`, `mergeable`, `mergeStateStatus`, `reviewDecision`, `autoMergeRequest`.

## Decision
- **Detection**: `pr-link` records (head and tail of the transcript, de-duplicated) plus a PR URL in the first prompt. No writes.
- **Data**: `GitHubService` actor wraps `gh` (`pr view --json`, `pr diff`, `pr checks`, `pr ready`, `pr merge [--auto|--disable-auto]`). Without `gh` or a login the chips still show numbers and the page explains what to install/run.
- **Mark** (`PullRequestMark`): state (draft/open/merged/closed) plus the most urgent attention: checks failing > conflicts > changes requested > unanswered comments > checks pending > approved. Sidebar row shows the aggregate across the session's PRs; footer shows one chip per PR.
- **Page**: right column like the git page (⌘⇧P, chip click, footer button): header (title, number, state, author, head → base, +/−), tabs **Overview** (body as Markdown via `AttributedString`, links open in the browser), **Checks** (rollup rows with conclusion and link), **Timeline** (comments and reviews chronologically, Markdown bodies), **Files** (`gh pr diff` → reusable `DiffView`, read-only). Actions: Ready (draft), Merge (confirm; method preference merge/squash/rebase, default squash), Auto-merge / Disable auto-merge, Open on GitHub, and **Send to session** prompts — "address the CI failures", "resolve the conflicts", "address the review comments" — typed into the session only when it is idle.
- **Refresh**: on session open, when a new `pr-link` lands, every 5 minutes for open PRs of open tabs, and on demand.
- **Not now**: full GFM rendering (tables/alerts/details), image diffs, auto-open-on-attach, "rename session to PR title", "request Claude review" as a GitHub review.

## Consequences
- The diff view from [[ADR-052 Git Page]] is reused read-only.
- Mutating `gh` commands always confirm in a sheet; nothing runs on a timer except reads.
