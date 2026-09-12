---
status: accepted
date: 2026-09-11
tags: [adr, github, ui, notifications]
---
# ADR-128: Watching a pull request

## Context
User (2026-09-11): *"Thinking about notifications. It would be nice if the user has a toggle on the PR
panel to enable "Watching" and to send notifications when an inflight PR fails or succeeds."*

[[ADR-127 The PR Panel Refreshes On Events Not On A Timer]] made the panel keep itself current, and
closed by naming what it still would not do: *notifying when a watched check fails — the panel
updates, it does not knock*. Everything a knock needs was already there — a cadence that can be aimed,
a notification path with mute, history and a card ([[ADR-033 Notification Delivery]], [[ADR-066 Attention]]) —
except a way to say *tell me about this one* and a definition of what "it ended" means.

The shape of the problem is not the notification; it is the silence around it. A build that finishes
is news exactly once, to someone who was not looking, about the commit they were waiting on. Every
other firing is noise: the same green rollup read a second time, a week-old verdict replayed at
launch, a run belonging to a commit that has already been superseded.

## Decision
- **A bell in the panel's service strip turns *Watching* on**, filled and in Clinic's accent while it
  is on. Clinic's accent and not the service's, by [[ADR-116 The PR Panel Speaks Its Service's Visual Language]]'s
  rule: being told about this pull request is a thing *Clinic* does for you, and GitHub knows nothing
  about it. It is hidden once a pull request is merged or closed, where there is nothing left to watch.
- **The watch is persisted** in `ClinicState.watchedPullRequests`, by ref id, so it outlives a
  relaunch — and is dropped automatically when the pull request merges or closes, rather than
  accumulating watches on finished work.
- **A watch aims the cadence.** A watched pull request never falls to ADR-127's five-minute
  background tier: off screen with a result still coming it is read every 30 seconds, and its own
  pane on screen still wins with 15. A watch nobody polls is a watch that reports the news late.
- **`PullRequestWatch` (ClinicCore, pure) decides what is news.** `verdict` reduces a rollup to
  *passed* or *failed* — `cancelled` and `neutral` are neither, because the merge box does not call
  them failing either ([[ADR-087 Pull Request Panel Is Status-First]]) and a notification that
  contradicts what is on screen is worse than one that stays quiet. `completion` then decides whether
  this read is worth saying out loud, by three rules that each exist because of a notification nobody
  wants:
  - **the first read of a pull request announces nothing** — otherwise every relaunch replays last
    week's green build;
  - **only a run that was seen in flight completes** — the same verdict read again is not news;
  - **only on the commit that was being watched** — a head that moved between reads means these
    checks belong to a run that was never observed, and the next completion on it will announce
    itself properly.

  Which makes a re-run announce again, correctly: it goes back in flight, so its second ending is
  news a second time.
- **It knocks the way an agent does.** The verdict goes through `TabStore.notify` as its session's
  notification, so it obeys that session's mute, stays a card while Clinic is active and becomes a
  system notification when it is not, and never interrupts a reader already sitting on that tab. The
  entry reads *«PR title» / #7 · build failed*, wearing the pull request glyph in green or red — the
  verdict is the colour, and what the row is *about* is the thing worth recognising in a list.
- **Clicking it lands on the checks.** The notification carries the ref, so `reveal` opens that pull
  request's pane rather than dropping the reader on whatever the tab last showed. The system
  notification carries it too, through `userInfo`.

## Consequences
- `NotificationStore.Entry.Kind` gains `checks(passed:)` and the entry an optional `PullRequestRef`;
  `NotificationService.post` and `onActivate` carry the pull request through the system notification.
- `PRStore` gains the watch list (through `SessionStore`, where state is persisted) and a router
  closure to `TabStore.notify`, as the background agents already had ([[ADR-061 Background Agents]]) —
  so the two stores still do not know about each other.
- Reads are now coalesced per pull request: opening a pane asked twice (the footer chip's
  `ensureLoaded` and the page's own `attach`), which paid for `gh` twice and, worse, could split a
  check transition between two concurrent reads so that neither saw it end.
- Worst case for a watch is one `gh pr view` every 30 seconds while a build runs, and nothing at all
  once it is settled or merged.
- **The boundary**: watching follows the session. The watch flag persists, but polling only happens
  while that session's tab is open — the store's whole surface is "pull requests of open tabs"
  ([[ADR-053 Pull Request Page]]). Close the tab and the watch sleeps until you open it again.
- 12 cases cover the verdict, the three silences and the cadence; the round trip was verified in a
  smoke instance against a stubbed `gh` whose check flips mid-run, in both directions.
- **Not now**: watching from the sidebar or the footer chip without opening the panel; a watch that
  survives its tab being closed; notifying on review or merge events, which are the same machinery
  and a different question about what counts as news.
