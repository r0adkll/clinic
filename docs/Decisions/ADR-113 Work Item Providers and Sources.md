---
status: accepted
date: 2026-09-10
tags: [adr, architecture, tasks, github, cli]
---
# ADR-113: Work item providers and sources

## Context
[[ADR-112 Tasks Screen]] lists issues from GitHub, and the user asked for the design to leave room
for GitLab *"and other task provider integrations"*. GitHub and GitLab issues belong to a
repository, so a project maps onto them cleanly. Linear, Jira and the like belong to a workspace or
team, and no checkout points at them.

Facts that shaped this, all checked on 2026-09-10:
- A `Project` is a folder path and nothing else. The only place a remote is read is "Open on GitHub"
  in the project menu, and it hard-codes `origin`.
- `GitHubService` is the one actor that runs `gh` ([[ADR-053 Pull Request Page]]). It has an
  `Operation` enum, a static `arguments(for:)`, hand-written parsers, and availability that tells
  "missing" apart from "logged out" ([[ADR-086 Tool Discovery and gh Availability]]).
- The `AgentAdapter` protocol [[ADR-004 Agent Scope]] describes was never built, so there is no
  provider pattern in the code to follow.
- Asking `gh issue list --json` for `comments` returns up to 100 **full comment bodies per issue**,
  and there is no count-only field. On `cli/cli`, 20 issues came to 73 KB for comments alone,
  against 64 KB for every other field together.

## Decision
### Vocabulary
The model word is `WorkItem`. An issue, a GitLab issue, a Linear issue and a Jira ticket are all
one. The UI word is **Tasks** ([[ADR-025 Vocabulary]]). The model avoids `Task` because it would
collide with Swift's `Task` all through the concurrency code.

### Sources are not projects
- A **`WorkItemSource`** is a provider, a host and a scope: for GitHub, `github`, `github.com` and
  `owner/repo`. Its id is `github:github.com/owner/repo`.
- A **project links to 0…n sources**. A GitHub source is derived automatically. A Linear team could
  later exist with no project at all, or be linked to one by hand, and nothing here would need to
  migrate.
- **Resolving a project.** Clinic runs `gh repo view --json nameWithOwner,url` **with the project as
  its working directory**, so the answer is whatever `gh` itself would use in that folder:
  - a `gh repo set-default`, if one was made;
  - otherwise the first remote in `upstream`, `github`, `origin` order.

  A fork therefore lists `upstream`'s issues. The host comes from the returned URL, so GitHub
  Enterprise needs no extra code: it works wherever `gh` is logged in.
- **Unresolved reasons** are taken from `gh`'s stderr: "Not a git repository", "No git remote", or
  "No GitHub remote gh knows". The last also covers an Enterprise host `gh` is not logged in to.
- **Override**: `ClinicState.taskSources[projectPath]`.
  - No entry means Automatic.
  - A list of sources replaces the automatic one.
  - An empty list means None.

  It is edited by **Task Source…**, in the project context menu and in the Tasks scope column.
- Resolution runs when the screen first appears and again on ⌘R. It is cheap, but a folder's remote
  rarely changes, so the 5-minute timer skips it.

### The protocol (ClinicCore, Foundation-only)
```swift
public protocol WorkItemProvider: Sendable {
    var kind: String { get }                                   // "github"
    func availability() async -> ToolAvailability
    func viewerLogin(host: String) async -> String?
    func resolveSources(projectPath: String) async -> WorkItemSourceResolution
    func list(_ source: WorkItemSource, state: WorkItemState, limit: Int) async throws -> WorkItemPage
    func mentioningViewer(host: String) async throws -> [WorkItemRef]
    func detail(_ ref: WorkItemRef) async throws -> WorkItemDetail
    func sessionPrompt(for item: WorkItem) -> String           // ADR-114
}
```
- **Providers return normalized items**:
  - `WorkItem`: ref, title, body, state, author, assignees, labels with colour, milestone, comment
    count, and the created, updated and closed dates.
  - `WorkItemDetail`: rendered body, comments, and linked PRs.
- **Filtering, search, sorting and counts** are one pure function over normalized fields
  (`WorkItemFilter`), so GitLab only has to implement the protocol.
- `ToolAvailability` is the old `GitHubService.Availability`, moved out and kept under that name as
  a typealias, so the PR code is unchanged.
- **`GitHubWorkItemProvider` wraps the existing `GitHubService`**, which gains the issue operations.
  `gh` still has one actor, one availability cache and one viewer-login cache. A second
  `GitHubIssueService` was considered and rejected: it would duplicate all of that for nothing.

### Transport
- **List: paginated GraphQL through `gh api graphql`, one repository per call chain.**
  - One query per 100 items: `repository.issues(states:, orderBy: UPDATED_AT DESC)`, with
    `comments { totalCount }` in place of the comment bodies.
  - This **supersedes the grilling's `gh issue list --json`**. That choice assumed the list call was
    cheap. A comment count is needed for the row and for the Comments sort, and `gh issue list`
    can only supply one by shipping every comment.
  - What made `gh issue list` attractive still holds: the argv is built by a static
    `arguments(for:)`, parsed by a pure function, and tested against a fixture, just like
    `pr view --json`.
  - Clinic drives the pagination itself with `-F after=<cursor>`, not `--paginate`. It stops exactly
    at the limit and does not depend on the `gh` release that added `--slurp`.
- **Limits**:
  - Open items: up to **1000** per source. The footer says when a source is truncated.
  - Closed items: the **200 most recently updated** per source, fetched only while the state filter
    includes Closed, and never cached.
- **Mentioned**: one `gh search issues --mentions @me --state open` call per host per refresh,
  intersected with known sources. The list query has no mentions field. `GH_HOST` selects an
  Enterprise host.
- **Detail**: one GraphQL call for `bodyHTML`, the first 100 comments with their `bodyHTML` and
  author avatars, and `closedByPullRequestsReferences`.
- **Refresh**: on appear (skipped if the last refresh was under 30 s ago), every **300 s while a
  Tasks screen is visible**, and on ⌘R. At most **4** `gh` processes run at once, and one slow or
  broken repository never blocks the rest. Nothing runs while no window shows the screen.

### Cache
- `Application Support/Clinic/work-items/<source id, sanitized>.json`, one file per source, holding:
  - `fetchedAt`
  - the open items
  - a `truncated` flag
  - `lastViewed` per item number

  [[ADR-021 Persistence]] keeps caches out of `state.json`, and this follows the `mcp/<id>.json` layout.
- The screen draws from the cache instantly and swaps in fresh data as each source lands. A failed
  source keeps its cached items and marks them stale.
- Detail HTML is never written to disk.
- The source overrides and the issue↔session links are Clinic's own decisions, not caches, so they
  go in `state.json`.

## Consequences
- `GitHubService` gets a working-directory and extra-environment path for `repo view` and `search`.
  `GitHubUnavailableView` names what it is reading ("pull requests" or "issues").
- Adding GitLab means writing a `GitLabWorkItemProvider` over `glab` and having `TasksStore` hold
  more than one provider. The screen, the filter and the cache don't change.
- Not in v1: issue types, sub-issues and Projects (v2) fields. All three need GraphQL fields that
  only GitHub has. The protocol leaves room for an optional type and hierarchy later.
