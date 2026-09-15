---
status: accepted (built 2026-09-14)
date: 2026-09-14
amends: "[[ADR-076 Project Icon Generation]] (its explicit `invalidate` gains a file watcher behind it)"
tags: [adr, ui, projects, watching]
---
# ADR-154: The project icon follows its file

## Context
User (2026-09-14): *"When you add a new project and say generate or add a new project icon it won't
update immediately in the editor. Is there a way we can watch for that file, or register for filesystem
changes of the icon file to live update the icon if its added/changed?"*

[[ADR-050 Project Decoration and Actions]] resolves an icon from four candidate files
(`project-icon.svg|png`, `.clinic/icon.svg|png`) and [[ADR-076 Project Icon Generation]] gave
`ProjectIconCache` an explicit `invalidate(path)` that only Clinic's own *Use* and *Remove Generated
Icon* call. An icon that arrives any other way — dropped in by hand, written by a session Claude is
running in the terminal, pulled in with a `git pull`, or drawn in an editor — sat behind a stale cache
until relaunch. The cache had no way to hear about the disk.

## Options
- **Poll the four files on a timer.** Rejected: [[ADR-127 The PR Panel Refreshes On Events Not On A Timer]]
  already settled that Clinic listens rather than asks, and a sidebar of thirty projects would stat 120
  files every tick for an event that happens a few times a month.
- **One `FSEventsWatcher` per project root.** Rejected: FSEvents is recursive by construction, so
  watching a repo root for two files means being woken by every build artefact under it. The editor
  and diff panels pay that price because they need the whole tree; the icon does not.
- **Reuse `DirectoryWatcher`.** Rejected: it watches a root and *every* immediate subdirectory (ADR-029's
  shape, `~/.claude/projects`), skips hidden entries so `.clinic/` is invisible to it, and only hears
  directory-entry changes — an in-place overwrite of an existing `icon.svg` never fires.
- **A non-recursive watcher on exactly the paths that matter.** Chosen.

## Decision
- **`PathWatcher` (ClinicCore)** watches a fixed set of paths with kqueue vnode sources, one descriptor
  per *anchor*: the path itself when it exists, otherwise its nearest existing ancestor. A repo with no
  `.clinic/` costs one descriptor on the repo root; when the directory appears the watcher re-anchors
  onto it, and when the file appears, onto the file — so a later in-place write is heard too. Every
  event closes and reopens all sources (descriptors follow inodes; an atomic save or a delete would
  otherwise leave a source on a ghost), debounced at 300 ms, and emits one `Void`.
- **`ProjectIconCache` watches the four candidates of every project** the sidebar lists (`SessionStore`
  hands it the roster each time it rebuilds; Chats is excluded, it has no icon). When it fills the cache
  for a project it records a **stamp** — existence, size and modification time of each candidate — and
  on a watcher event it reloads only the projects whose stamp differs. Churn in a repo root that is not
  an icon (build output, a `.DS_Store`, a lockfile) reaches the watcher and stops there.
- **The existing `invalidate` and `revision` stay the mechanism.** The watcher is a second caller of the
  ADR-076 path, not a new one; *Use* in the generate sheet still invalidates immediately and the watcher
  event that follows finds nothing changed.
- Reloads are logged at info under category `icons`, so the chain is verifiable with `/usr/bin/log`.

## Consequences
- An icon added, overwritten or removed on disk redraws in the sidebar, the notification card and the
  new-session screen (and its tint, ADR-082) within about a third of a second, however it got there.
- One kqueue descriptor per project (up to three while `.clinic/` and an icon both exist). Nothing
  recursive, nothing periodic.
- `PathWatcher` is the third watcher in ClinicCore, beside `DirectoryWatcher` (a root and its children)
  and `FSEventsWatcher` (a whole tree). Pick by shape: a known set of paths that may not exist yet is
  this one.
- A project removed from the sidebar drops out of the watched set on the next roster rebuild; the cache
  entry for it stays until `invalidate()`, as before.
