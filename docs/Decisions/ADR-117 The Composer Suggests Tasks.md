---
status: accepted
date: 2026-09-10
supersedes: the quick-starts bullet of ADR-082, and ADR-113's "nothing runs while no window shows the screen"
tags: [adr, ui, sessions, tasks]
---
# ADR-117: The composer suggests tasks

## Context
[[ADR-082 New Session Screen Composer]] put up to three quick starts under the composer card, all of
them the project's own recent first prompts. Since then, [[ADR-112 Tasks Screen]] and
[[ADR-113 Work Item Providers and Sources]] have given every project a list of open issues. The
composer never showed them: the only way from an issue to a session was the Tasks screen's Start
Session ([[ADR-114 Starting A Session From A Task]]).

User (2026-09-10): *"Let's pull some of the new session auto suggestions from the tasks provider(s)
for the project."*

The obvious ranking is the Tasks screen's own sort, most recently updated first. On
r0adkll/upload-google-play that surfaces three issues assigned to another maintainer before either
of the two assigned to you, so it isn't enough on its own.

## Decision
### What is suggested
- **Up to three open tasks from the project's own sources**, in two labelled rows under the card:
  **Tasks**, then **Recent** (the old quick starts, unchanged).
- **Ranking** is `WorkItemSuggestions.rank`, a pure function in ClinicCore over normalized items, so
  any provider gets it for free:
  1. assigned to you;
  2. mentioning you, or filed by you;
  3. assigned to nobody.

  Each tier is ordered by last update.
- **Left out:**
  - closed items;
  - items that already have a session in `workItemLinks`, because they are already under way;
  - items assigned only to other people, because they are someone else's work.

  While the viewer on a host is unknown, nothing can be told apart, so every open item there ranks
  by recency alone.

### What choosing one does
- It does what Start Session does from the Tasks screen:
  - the provider's `sessionPrompt(for:)`;
  - the worktree on, named `issue-<n>-<slug>`;
  - the draft linked to the item, so Send records the link.

  The pill turns accent with a ✓.
- **Choosing it again unlinks it.** The prompt and the worktree name are cleared too, but only if
  they are still exactly what the pill filled in, so anything typed over them stays.
- Choosing a Recent prompt unlinks a task the same way.
- This is the "attach an issue from the composer" item the [[Backlog]] held against ADR-114, for the
  project's own suggested tasks. Searching for an arbitrary issue from the composer is still not built.
- A pill wears the service's mark and the issue number; the full `owner/repo#n` and title are in the
  tooltip.

### When it fetches
- **`TasksStore.composerAppeared(projectPath:)`** runs when a composer opens:
  - it draws from the on-disk cache at once;
  - it resolves the project if it was never resolved, and learns the viewer login on each of its hosts;
  - it re-fetches **that project's sources only**, if their cache is older than **300 s** (the Tasks
    screen's poll interval).
- This supersedes ADR-113's *nothing runs while no window shows the screen*. A composer is one project
  and a handful of `gh` calls, at most once per five minutes, and it runs only when a person is
  looking at it.
- The mention search is **not** run for the composer. It is one search per host, and it only moves an
  item between tiers 1 and 3. The last result from the Tasks screen is used if there is one.

## Consequences
- `NewSessionScreen` reads `TasksStore` from the environment. `quickStarts` becomes two
  `quickStartRow`s, and `taskPill` / `attach` / `detachTask` join it.
- A task started from anywhere drops out of the suggestions from then on, because it now has a
  session. The Tasks screen still lists it, with its session count.
- Not in v1:
  - a setting to hide task suggestions;
  - suggestions for Chats, which has no repository;
  - a search field that attaches an arbitrary issue.
