---
status: accepted (built 2026-10-08)
date: 2026-10-08
amends: "[[ADR-037 Close Quit and Exited Flows]] and [[ADR-063 Session Lifecycle Controls]] (what a graceful close waits for), [[ADR-065 Repo Upkeep]] (when the archive offer runs)"
tags: [adr, sessions, git, worktree, ui]
---
# ADR-190: Clinic answers the worktree exit dialog

## Context
User (2026-10-08): *"When closing a session (or attempting to archive) Claude will prompt what to do
with the worktree in the terminal and sometimes I miss it."* Then: *"we should default to 1, and have a
setting that lets us configure the answer. It might also be nice to do some 'pre-' detection when
clicking these closing actions and determining if Clinic should prompt the user for confirmation and
then use that answer to respond."*

Measured against CLI 2.1.295, driving `claude -w` in a scratch repository through a pty with a
`SessionEnd` hook that logs the time:

- As an interactive worktree session exits, the CLI shows *Exiting worktree session* with *1. Keep
  worktree* and *2. Remove worktree*, *Enter to confirm · Esc to cancel*. A bare digit both selects
  and confirms: `2` alone removed the worktree **and its branch**, uncommitted work discarded. There
  is no Trash.
- **`SessionEnd` fires only after the dialog is answered.** Answering Keep logged the hook 0.3 s
  later; before the answer, nothing.
- The dialog shows when the worktree holds changed or untracked files or commits of its own, or
  when the session is named. A clean worktree of an unnamed session is removed silently (docs,
  *Clean up worktrees*). Clinic names only `--bg` sessions, so its interactive sessions are unnamed
  unless the user ran `/rename`.
- No flag or setting skips or pre-answers the dialog. `WorktreeRemove` fires only for worktrees a
  `WorktreeCreate` hook made, which Clinic's never are ([[ADR-098 WorktreeCreate Is Not Ours]]).

So Clinic's close was the thing losing the prompt. [[ADR-063 Session Lifecycle Controls]]' graceful
close sends Ctrl‑C twice, waits for `SessionEnd`, and after five seconds frees the surface. For a
worktree session with work in it the dialog appeared, nobody answered, and the fallback killed the
CLI mid-dialog: the tab vanished with the question on it. Two faults followed from the same order.
Archive (`SessionActions.archive`) stopped when `close` returned false, which a pending graceful
close always does, so a running worktree session was never archived and the Keep/Trash offer of
[[ADR-065 Repo Upkeep]] never ran. Stop (⌘.) left the dialog waiting with no `SessionEnd`, and the
tab read as running until someone looked at the terminal.

## Options
- **Kill the process instead of exiting cleanly.** No dialog, worktree always kept. Rejected: ADR-063
  chose the clean exit so `SessionEnd` seals the last turn.
- **Answer the dialog from Clinic**, the way [[ADR-180 Permission Prompts Are Answered From Clinic]]
  presses a digit into the permission prompt. Chosen. The CLI stays the one that removes or keeps;
  Clinic is the reader's hands.
- **Always press Keep and then trash through ADR-065**, so nothing is ever deleted outside the
  Trash. Proposed first, and narrowed by the user: Keep is the default, but the answer is a setting,
  and the CLI's own Remove is offered when it is what the user wants.

## Decision
- **A setting answers: Keep (default), Remove, or Ask.** `WorktreeExitAnswer` (ClinicCore), stored as
  `ClinicWorktreeExitAnswer`, shown in Settings → Sessions → *Worktrees* beside the archive
  preference. Its footer says that Remove is the CLI's own and takes the branch and the work with it.
- **The closing actions look at the worktree first.** When a running session's directory lies under
  `.claude/worktrees/` (`WorktreeExitFacts.worktreeRoot(forCwd:)`), Close and Stop read
  `GitRepository.worktreeExitFacts(at:)` — uncommitted files, commits the default branch lacks, the
  branch — before anything is sent to the CLI.
- **Then they ask once, in Clinic's sheet.** *Close this session?* names the worktree, says what it
  holds (*It holds 2 uncommitted files and 1 commit of its own on worktree-x.*) and what the setting
  will do to it. Under *Ask*, a popup in the sheet takes the answer, Keep first. A clean worktree's
  sheet says the CLI removes a clean worktree itself unless the session was named. Background stays
  on the close sheet as before. Stop asks only under *Ask*; otherwise it stops at once with the setting.
- **The answer is pressed when the dialog shows.** `stop` starts a watcher that reads the surface's
  visible text every 150 ms for up to fifteen seconds; `WorktreeExitDialog.isShowing(in:)` matches
  the dialog with its whitespace removed, since Ink lays it out with cursor moves and wraps the path,
  and stops matching once *Keeping worktree…*, *Removing worktree…* or *Worktree removed* follows it.
  On a match it presses `1` or `2` as a key event (`pressKey`, ADR-180), once.
- **The graceful close waits for the answer to land.** Its five-second fallback restarts when the
  dialog was just answered, because a removal is still running, and never fires while the dialog is
  on screen unanswered: closing then would kill it with the question unasked. `SessionEnd` closes
  the tab as before.
- **Archive awaits the close.** `TabStore.closeAndWait` returns once the tab is gone or false when
  the user cancelled or chose Background; a cancel still stops the whole group (ADR-181). The
  ADR-065 Keep/Trash offer is skipped for a worktree the close sheet already asked about or that
  the CLI removed; under a silent Keep it still runs, as it did.
- **Quit takes the setting without asking**, Keep under *Ask*: the quit sheet is already one
  question, and a worktree kept can be trashed later from Archive.

## Consequences
- ClinicCore gains `Git/WorktreeExit.swift`: `WorktreeExitAnswer`, `WorktreeExitDialog`,
  `WorktreeExitFacts` and `GitRepository.worktreeExitFacts(at:)`, with `WorktreeExitTests` over the
  dialog text the probe read, the root finder, the summary and a real worktree.
- `Tab` carries `worktreeExitAnswer`, `worktreeExitWatcher` and `worktreeAnsweredAt`, cleared when a
  session ends in a tab that stays. `TabStore` gains `stopSession` (menu and rows ask; `stop` does
  not), `closeWorktreeSession`, `closeAndWait`, `confirmCloseWorktreeTab`, `worktreeExitSetting`.
- New smoke key (ADR-038): `-ClinicNewSessionWorktreeOnLaunch <name>` beside `-ClinicNewSessionOnLaunch`,
  so `-ClinicStopAfterLaunch` meets the dialog.
- The dialog that appears outside a Clinic-driven stop — the user typing `/exit` or Ctrl‑C in the
  terminal — is not watched for; nothing triggers a read. Surfacing it on the card and the
  notification, like a permission prompt, is left for later.
- If the CLI ever gains a flag or setting that pre-answers the dialog, the watcher should go and
  the answer should ride on the launch instead.
