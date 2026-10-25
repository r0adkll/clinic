---
status: accepted (built 2026-10-25)
date: 2026-10-25
amends: "[[ADR-225 Crashes Leave Evidence]] (a report also carries the breadcrumbs and any layout loop running at the throw, and a loop leaves a file of its own) and [[ADR-153 Versions Are Semver And A Release Updates The Tap]] (the GitHub Release also carries the build's dSYMs)"
tags: [adr, ops, diagnostics, bug, release]
---
# ADR-231: Layout loops are witnessed, and releases keep their symbols

## Context
Installed Clinic 0.6.0 died again on 2026-10-24 at 21:29. It was [[ADR-225 Crashes Leave Evidence]]'s
exception: *the window has been marked as needing another Update Constraints in Window pass, but it has already
had more … than there are views in the window*. The app hung for about 20 seconds first. ADR-225's recorder
worked and wrote `diagnostics/exception-2026-10-25T01-29-00.944Z.json`. A report from a crash on 2026-10-21 at
11:38 had been sitting beside it, never read.

Neither report could name the cause. Every frame of the loop is AppKit's or SwiftUI's. That night's unified log
had more, because AppKit turns on display-cycle logging near its limit. Each pass ran:
- `NSHostingView.layout` → render → `preferencesDidChange`;
- → `AppKitWindowController.updateToolbarBridge` → `ToolbarBridge.preferencesDidChange`;
- → `Toolbar.LocationStorage.updatedVendedItems(newFocusedValues:)` → `invalidateProperties`;
- → `NSHostingView.setNeedsUpdate`, and the window needs another pass.

So the toolbar's content came out different on every render. Across the five crashes (three on 10-17, then
10-21 and 10-24):
- the selected session was working every time;
- the window was 1800×1130 every time;
- the first came two days after [[ADR-212 A Session Is A Workspace Of Tabs]] moved the session header into the
  toolbar.

Two other limits:
- The unified log kept about three days: the 10-21 crash had already rolled out.
- A release build's `Logger` info and debug messages are not kept at all.

User: *"This crash happens very infrequently and is hard to predict. Is there more error reporting / logging in
release builds we could add to help narrow this down?"* Then, of the proposal: *"Yes, lets build them. For #6, we
should upload the dSYMs to the GH release (maybe as a zip?) to keep track of them"*.

Found while building:
- **Swift 6.4's `@Observable` does not notify when an `Equatable` value is written back unchanged.** A probe
  program armed `withObservationTracking`; writing the same `String?` or `Bool` fired nothing, and a changed
  value fired. So `TabStore`'s unconditional `tab.pwd = p` cannot drive the loop, though it was a suspect.
  Trackers see what SwiftUI sees, which is changes.
- **Normal display cycles take several passes.** In Clinic Dev (Debug, 2026-10-25), a turn of the run loop took
  up to 25 window passes at launch and about 10 when a session opened. The real loop took about 550, AppKit's
  limit being the window's view count (547 that night).

## Options
1. **More at the throw**, such as a longer stack. The frames are Apple's. Rejected.
2. **`Self._printChanges()` or `_logChanges()` in release.** For `@Observable` dependencies they only say
   *@dependencies changed*, without naming any. Rejected.
3. **A loop witness**: detect the loop from inside, then record each pass. That means which observed values
   changed, which of Clinic's views ran, and the AppKit side. Add a breadcrumb trail for what led up to it,
   and write a file at the trip, not only at a crash.
4. **A brake**: once tripped, freeze the toolbar's inputs for the rest of the turn. That would turn a crash into
   a stale toolbar, but it would also hide the evidence. Deferred until the cause is named.

## Decision
Option 3, and every release keeps its debug symbols.

**Counting passes.** `LoopWitness` swaps `-[NSWindow updateConstraintsIfNeeded]` for a counting version
(`method_exchangeImplementations`). The display cycle calls it once per pass. The count is kept per window and
starts again each turn of the main run loop: a `CFRunLoopObserver` for `beforeSources | beforeWaiting`, in the
common modes. A busy main thread that keeps turning over never adds up.

**Tripping.** 100 passes in one turn trips the witness: four times the most seen while settling, and room for
about 450 recorded passes before AppKit gives up. On a trip:
- **One observation tracker per value the window's views read**, re-armed after each pass:
  - the window: selection, screen, composer, select mode;
  - the selected tab: state, `waitingOn`, unread, error badge, `pwd`, kind, replay, opened title, `childExited`,
    `isAttached`, branch, model, effort, status line, focused area, both areas' panes and selection, and the
    panel's visibility;
  - app-wide: tabs, windows, active window, sessions, Clinic state, projects, activities, runs (runs, files,
    detected), caffeine, sound packs, notifications, PRs, usage.
- **The window's main Clinic views note themselves** when their body or update runs, counted only while
  tripped: `RootView`, `Sidebar`, `SessionCard`, `DetailView`, `TabFooter`, `RootToolbar`, `SessionHeader`,
  `TerminalStack.update`.
- **Each of the next 60 passes is recorded in full:**
  - its number and milliseconds since the trip;
  - the values changed and the views run since the pass before;
  - the first responder, as class and address;
  - each toolbar item's identifier and width, or *hidden* when it went into the » menu, read from the item views
    without asking the toolbar for layout;
  - the window's frame.

  After that, only per-value and per-view totals are kept.

**Files.** `diagnostics/loop-<time>.json` (`LoopReport`) holds the record, the breadcrumbs, the workspace dump
and the versions. It is written once the 60 passes are in, then rewritten:
- when the run loop turns over (`survived: true`);
- when an exception is thrown during the loop (`survived: false`).

At most 5 loop files per launch, so a window that loops and recovers cannot push crash reports out of the
archive's 30. The loop's start and end go to the log at `error`, which a release build keeps.

**Breadcrumbs.** A trail of the last 300 events (`BreadcrumbTrail`, ClinicCore). A crumb with a key folds into
one with the same key among the last 8, moves to the end and counts a repeat, so a title spinning ten times a
second takes one slot. It records:
- hooks, with the tool name (the status line folded per session);
- state transitions and selection;
- the terminal's title, directory (*now* or *again*) and progress, folded per tab;
- session re-reads and rescans;
- titled windows' and sheets' key, sheet, full-screen, screen, minimise and close events, and resizes folded per
  window;
- each window's first responder, by key-value observing, folded per window.

It is behind a lock, so the uncaught handler can read it from any thread.

**Reports.** `ExceptionReport` gains `breadcrumbs` and `loop`. Diagnostics dates are written to the millisecond
by one shared encoder; the decoder still reads ADR-225's whole-second dates.

**The probe.** `-ClinicLoopProbe <passes>` loops the key window for that many passes, five seconds after
launch. A view dirties its constraints from `layout()`, as SwiftUI does, and flips the selected tab's `pwd` by a
trailing slash each pass.

**Symbols.** `scripts/release.sh` zips the archive's dSYMs as `Clinic-<version>-dSYMs.zip`, without AppleDouble
files. It first checks that `Clinic.app.dSYM`'s UUID matches the exported binary's. `scripts/publish` uploads the
zip to the GitHub Release beside the app's and says what it is in the notes. A reused build without the zip is
rebuilt.

## Consequences
- The next loop, fatal or not, names per pass the values that changed, the views that ran, where focus was, and
  how wide each toolbar item was, plus what happened in the minutes before. If no tracker fires on each pass, the
  driver is inside SwiftUI's focus or toolbar handling, and the first-responder and toolbar columns are the lead.
- Checked in Clinic Dev:
  - **Normal use**: a session, with the panel shown, hidden and shown again, left no loop file.
  - **`-ClinicLoopProbe 200`**: tripped at 100, ended at 215 passes in 0.38 s, `survived: true`. `tab.pwd`
    changed in 103 passes; `RootToolbar` and `TabFooter` ran 104 times each. Focus was on the session's
    `GhosttySurfaceView`, and five toolbar items measured 38, 212, 36, 351 and 36 pt.
  - **`-ClinicLoopProbe 10000`**: AppKit threw the same *more Update Constraints in Window passes* exception after
    2825 passes in 8.3 s. The exception report carried the loop record, the breadcrumbs and the workspace, and the
    loop file was rewritten with `survived: false`.
  - **A first probe** re-dirtied constraints inside `updateConstraints`. AppKit refused it at once with an
    `NSInternalInconsistencyException`, which is why the probe dirties from `layout()`. That crash's report
    carried 10 breadcrumbs.
  - **Focus crumbs** arrived once session windows were watched from `TabStore.bind` rather than from first
    becoming key: a window launched in the background never became key.
- Swapping a public `NSWindow` method in a release build costs a dictionary increment per pass. If AppKit ever
  stops sending the message, the witness goes quiet and never trips; nothing fails. Checked on macOS 26.6.2.
- A window with fewer than 100 views would reach AppKit's limit before the trip. Session windows have hundreds.
- A loop spread over many turns, a pass or two per frame, is not caught. It is not the crash's shape.
- Same-value writes are invisible to the trackers, but they are invisible to SwiftUI too.
- **dSYMs:** the 0.6.0 dSYM still in `build/release` matches the installed 0.6.0 (`C6E2080F-773B-…`) and zips to
  79 MB. Earlier releases' symbols are gone, and 0.6.0's go with the next build unless uploaded.
- **Not verified:** a full `make release` and `make publish`. The new dSYM step ran alone against the 0.6.0
  archive, and `publish` compiles.
- `LoopEvidenceTests` (6) pin the trail's capacity and folding, a loop report's round trip to the millisecond,
  and that an ADR-225 report still reads.
