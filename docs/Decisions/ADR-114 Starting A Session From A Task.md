---
status: accepted
date: 2026-09-10
tags: [adr, sessions, tasks, worktree]
---
# ADR-114: Starting a session from a task

## Context
The Tasks screen ([[ADR-112 Tasks Screen]]) is a launchpad as well as a viewer. Clinic can already start a
session with a prompt and a worktree in one call (`TabStore.newSession`), and the new-session screen
keeps a per-project draft that a caller can fill in first ([[ADR-071 New Session Screen]],
[[ADR-082 New Session Screen Composer]], [[ADR-083 Worktree Control]]).

## Decision
### The hand-off
- **Start Session opens the composer, pre-filled.** It is the ↩ key, and the detail pane's primary button.
  The composer comes up with:
  - the issue's project;
  - the worktree **on**, named `issue-<number>-<slug>`;
  - the prompt below.

  You can review and edit any of it, then press Send.
  - Starting a session is costly enough to earn a review step.
  - Pre-filling replaces that project's unsent draft. Drafts are per-project scratch, and this is
    an explicit request for a new one.
- **⌘↩ (or ⌥-click on Start Session) starts it immediately** through `TabStore.newSession`, with the
  same prompt and worktree and the project's last model.
- **Which project** runs the session:
  - the project selected in the scope column, if it has the issue's source;
  - otherwise the first project in roster order that does.
- **Slug**: the title in lowercase ASCII, with runs of anything else collapsed to `-`, cut to 40
  characters at a word boundary. It becomes the CLI's worktree and branch name.

### The prompt
Every provider supplies its own prompt (`WorkItemProvider.sessionPrompt(for:)`). GitHub's is:

```
Work on GitHub issue owner/repo#123: "<title>"
<url>

Start by reading it with `gh issue view <url> --comments`.
```

- It is a **reference, not the body inlined.** Claude reads the issue fresh through `gh`, comments
  included, so a long body doesn't bloat the first turn or go stale.
- It names the issue **by URL**. With a source override ([[ADR-113 Work Item Providers and Sources]]),
  a bare `#123` could resolve against the wrong repository inside a fork.
- An editable template with placeholders is recorded as a follow-up, and would come with a Settings pane.

### Remembering the link
- `ClinicState.workItemLinks: [SessionID: [WorkItemRef]]` records each session started from a task.
  It is written **only by Start Session**. Nothing mines transcripts for issue URLs.
- It sits in `state.json`, not on `SessionSummary`. `SessionSummary.pullRequests` is derived from
  the transcript and rebuilt by the scanner, but this link is Clinic's own record and has to survive
  a rescan.
- **The issue shows its sessions**:
  - a count on the list row;
  - a chip for each session in the detail header, which opens the session.
- **The session shows its issue**:
  - a **Show Task** item in its context menu, which opens Tasks with the issue selected (it widens
    the view to All and clears the filters so the issue is sure to be listed);
  - a "Tasks" row in Session Details ([[ADR-059 Replay and Session Details]]).
- There is no chip in the tab bar or footer: that would add chrome to every session for a minority case.

## Consequences
- `NewSessionDraft` carries an optional `workItem`, and `sendDraft` passes it to `newSession`, which
  records the link.
- A session started this way is otherwise ordinary. The link is not shown anywhere else, and
  archiving the session leaves it in place, so the issue still lists the session.
- Not in v1: attaching an issue from inside the composer (the reverse hand-off), recorded in [[Backlog]].
