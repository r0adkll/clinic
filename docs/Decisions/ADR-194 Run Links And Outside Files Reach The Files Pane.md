---
status: accepted (built 2026-10-10)
date: 2026-10-10
amends: "[[ADR-192 Terminal File Links Open In The Files Pane]] (its *Not in scope*)"
tags: [adr, terminal, editor, panel, run]
---
# ADR-194: Run links and outside files reach the Files pane

## Context
[[ADR-192 Terminal File Links Open In The Files Pane]] left two gaps. Links in a run's pane still went
to the system. A file opened from a link outside the repository showed, but did not reload when it
changed. Both were packed into the same change as [[ADR-193 The Preview Highlights Code, Finds Text And
Draws Diagrams]].

## Decision

### A run's links open where the run is shown
- `RunStore`'s `open_url` handler passes a link to `TabStore.openInFiles` for the tab hosting the run
  (`hostTabId`). The system gets it only when that declines. A build's errors are the links most worth
  following.
- A relative path is read from where the run ran,
  `RunCheckout.workingDirectory(for:checkout:)`: the configuration's `directory` or the checkout. Not the
  tab's shell directory. `openInFiles` takes that as `cwd`.

### A file outside the repository is watched through its folder
- While the open file lies outside `root`, `EditorModel` runs a second `FSEventsWatcher` on the file's
  folder. It moves with the open file and stops when the file is back inside the tree or the pane
  closes. The folder rather than the file, because editors and agents save by writing a new file and
  renaming it over the old one. A change runs the same `externalChanged` the tree's watcher does: reload
  when clean, ask when dirty.
- *Found 2026-10-10:* the first version never fired. FSEvents reports real paths
  (`/private/tmp/plan.md`). The opened path had been through `standardizingPath`, which drops that
  `/private`, and `resolvingSymlinksInPath` drops it too, so no form of the open path ever matched the
  event. The two are now compared with a leading `/private` removed from both.

## Consequences
- `TabStore.openInFiles(_:from:cwd:)`. `EditorModel.watchOutside()`, called on open and rebind and stopped
  with the pane.
- The tree's own watcher still compares paths as it did. A repository under `/tmp` would hit the same
  `/private` mismatch there. That has not been seen and is left alone.
- Verified in Clinic Dev on 2026-10-10: a Markdown file in the session scratchpad (under `/private/tmp`),
  opened through `-ClinicOpenLinkAfterLaunch`, showed a section appended on disk three seconds later,
  in place. Not exercised: a link clicked in a run's pane.
