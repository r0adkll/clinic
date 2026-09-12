---
status: accepted
date: 2026-09-11
supersedes: the refresh rule in ADR-053
tags: [adr, github, ui, performance]
---
# ADR-127: The pull request panel refreshes on events, not on a timer

## Context
User (2026-09-11): *"It would be nice if the PR panel felt more responsive. Like in my recent
example, I had the agent push some changes but had to manually refresh the PR panel to see the
updates. Also with the checks, it feels like we should poll or poll more frequently if viewing the
panel while checks are in progress."*

[[ADR-053 Pull Request Page]] gave the panel one rule — *every 5 minutes for open PRs of open tabs,
and on demand* — written when the PR page was something you opened occasionally. Reading a pull
request while an agent works on it is a different activity, and the rule failed it in five ways:

- **One fixed cadence for every situation.** The timer did not care whether the pane was on screen,
  whether Clinic was even the active app, or whether a build was running. A pane nobody is looking at
  and a pane with four jobs in flight were polled identically.
- **Nothing event-driven, though the events were already in hand.** The `Stop` hook tells Clinic the
  exact moment a turn ended, and `TabStore` already re-reads the transcript there ([[ADR-026 Session State Machine]]).
  A push mid-turn is a write to `refs/remotes/…` that an `FSEventsWatcher` would have seen within a
  second — the same watcher the diff panel has run since [[ADR-080 Diff Panel]]. The panel used
  neither, so the answer to *the agent just pushed* was five minutes away, or a click on ⟳.
- **Opening the pane did not refresh it.** `PRPage` fetched only when nothing was cached, so
  returning to a pane after twenty minutes showed a twenty-minute-old pull request with nothing
  saying so.
- **The Files tab never reloaded at all.** `gh pr diff` ran once; nothing invalidated it, so after a
  push even ⟳ left the wrong diff on screen.
- **Every read flashed the timeline.** A refresh stored the fresh PR — which has no rendered HTML —
  and *then* fetched the rendering ([[ADR-090 GitHub-Rendered Bodies]]), so every body dropped to its
  Markdown source and swapped back a beat later. Harmless at five-minute intervals, and the reason a
  faster cadence could not simply be dialled in.

## Decision
**The clock becomes the backstop, not the mechanism.** Three things ask for a read; `PRStore` is the
only place that decides whether one happens.

- **A push is a file-system event.** One `FSEventsWatcher` per repository behind an open pane, over
  that repository's **git common directory** — `git rev-parse --git-common-dir`, so a linked worktree
  ([[ADR-083 Worktree Control]]) watches the main repository's `.git` where `refs/remotes` actually
  lives, not its own. Paths are filtered to `refs/remotes/…` and `packed-refs`; `FETCH_HEAD` is
  excluded because a plain fetch writes it with nothing having moved. The agent's push mid-turn and
  the user's push in the shell arrive by the same door.
- **The end of a turn is a hook.** `TabStore` bumps that session's pull requests on `Stop`, *after*
  the transcript re-read, so a turn that opened the PR is refreshed by the same signal that discovers
  it. This catches what a push does not: a comment answered, a review requested, a draft marked ready.
- **A bump is two reads, not one.** GitHub creates a commit's check runs asynchronously, so the read
  that fires the instant a ref moves usually finds no checks at all. A second read follows eight
  seconds later, which is what turns the panel into *running* rather than *nothing here*.
- **The cadence is a function of what is on screen** (`PullRequestRefresh`, in ClinicCore, pure):

  | Situation | Interval |
  |---|---|
  | On screen, a result still coming (checks running, or `mergeable`/`mergeStateStatus` still `UNKNOWN`) | 15s |
  | On screen, settled | 60s |
  | Pane behind another, or Clinic in the background | 300s — ADR-053's cadence |
  | Merged or closed | never again |

  `UNKNOWN` mergeability is in the fast tier deliberately: it is what GitHub reports in the seconds
  after a push, which is exactly when someone is watching.
- **Coming back refreshes.** A pane is only built while it is the front pane, so its `task` is also
  "came to the front": anything older than 20 seconds is re-read. Activating Clinic does the same for
  the pane on screen — and only that one, so activation never fans out into a read per open PR.
- **A fast read is a cheap read.** The rendered-HTML call is no longer part of every refresh. The
  rendering already in hand is re-applied to the incoming PR *before* it reaches the screen, and
  re-fetched only when a body or comment actually changed, or when the image URLs GitHub signs into
  it approach their five-minute expiry. A finished check now costs one `gh pr view`, and the timeline
  no longer flashes. ⟳ still forces the lot.
- **The Files tab tracks the head commit.** `headRefOid` joins the `gh pr view` fields; when it moves,
  the cached diff is re-read in place — the tab keeps showing the old files until the new ones land
  rather than falling back to a spinner — and the file tree is keyed on the commit, so a push that
  edits the same files again still rebuilds.
- **The panel says what it is doing.** ⟳ spins for the reader's own press and carries *updated 2
  minutes ago* in its tooltip. The Checks tab prints its own age, and while something is in flight,
  *Rechecking every 15s*. The automatic reads themselves are silent: a header blinking every fifteen
  seconds reads as jitter, not as life.

## Consequences
- `PRStore` owns a five-second tick that consults `PullRequestRefresh` per pull request, rather than a
  five-minute sleep that refreshes everything. A tick that finds nothing due spawns no process, and
  the tick itself backs off to 30 seconds when no pane is open.
- The store's provider now answers with `OpenPR` — ref, checkout directory, and whether that pane is
  the one on screen — so the store can decide cadence and watch refs without reaching into `TabStore`.
- Worst case is one `gh pr view` every 15 seconds for the single pull request being watched, ~240 an
  hour against a 5,000/hour limit, and only while Clinic is active and that pane is front.
- A read that fails no longer retries every tick: nothing cached plus a recent attempt waits out the
  slow cadence, so a repository `gh` cannot read is not hammered.
- `PullRequestRefresh` is pure and covered by 14 cases; the push signal is covered end to end over
  real git (init, push to a bare remote, assert the watcher emits a path `isRefUpdate` accepts) and so
  is the worktree's common directory.
- Every read logs which pull request, whether it is awaiting a result, and whether it paid for the
  rendering (`com.r0adkll.clinic:github`, debug), so the cadence can be read off `log stream` rather
  than inferred from the screen ([[ADR-038 Preferences and Diagnostics]]).
- The sidebar and footer marks are read from the same store, so they sharpen with the panel.
- **Not now**: notifying when a watched check fails (the panel updates, it does not knock) — *done the
  same day by [[ADR-128 Watching A Pull Request]]*;
  `gh pr checks --watch`, whose long-lived process buys nothing over a 15-second read; and check
  *failure output*, still the thing this layout most wants ([[ADR-087 Pull Request Panel Is Status-First]]).
