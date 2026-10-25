---
status: accepted (amended by ADR-231: reports carry breadcrumbs and any layout loop, and a loop leaves its own file)
date: 2026-10-17
amends: "[[ADR-038 Preferences and Diagnostics]] (where a crash's evidence goes) and [[ADR-212 A Session Is A Workspace Of Tabs]] (the pane host's bar heights)"
tags: [adr, ops, diagnostics, bug]
---
# ADR-225: Crashes leave evidence

Numbered 225 because ADR-224 is taken on the unmerged `worktree-zazzy-drifting-parasol` branch
([[ADR-224 Emulators Run In A Device Pane]]).

## Context
Installed Clinic 0.5.0 died twice on 2026-10-17, at 11:26:41 and 11:33:30. Both times AppKit raised
`NSGenericException`: *the window has been marked as needing another Update Constraints in Window pass, but it
has already had more … than there are views in the window*. It is a layout loop, the same failure as
[[ADR-148 The Conversation Is Not Lazy]] and [[ADR-178 The Usage Panel's Invitation Is Bounded]]. In the second
trace the window's root view re-renders and the toolbar sees changed items on every pass.

The investigation could not name the cause, because the process left almost nothing behind:
- **No crash report.** After an exception in a display cycle, AppKit logs it and ends the process with
  `exit(6)`, which launchd reports as status 1536. That is not a signal, so ReportCrash writes nothing.
- **Nothing runs on the way out.** Tried in Clinic Dev with an exception thrown from a view's `layout()`:
  - `NSApplicationCrashOnExceptions`, as an Info.plist key and as a registered default;
  - `NSSetUncaughtExceptionHandler`;
  - `atexit`;
  - wrapping `-[NSApplication reportException:]`.

  None of them ran. Subclassing `NSApplication` is not an option either: SwiftUI installs its own
  `AppKitApplication` whatever `NSPrincipalClass` says.
- **No record of the workspace.** [[ADR-223 A Session Comes Back Fresh]] keeps no layout on disk, so which panes
  were open died with the process. Neither the user nor the session working beside them could say which.
- **Noise in the log.** Every session opened logged *Unable to simultaneously satisfy constraints*. The pane host
  is first laid out at zero height against its required 34 pt tab strip, and AppKit recovered by breaking the
  strip's height or Claude's surface's pin. That happened dozens of times in the dead process's life.

## Options
1. `NSApplicationCrashOnExceptions` alone. It does nothing on this path (tried).
2. A third-party crash reporter. That needs a service and an ADR-058 adoption, and it hooks the same points that
   failed here.
3. **Catch the exception where it is thrown**, write the evidence at once, and withdraw it if the app survives.
   Archive MetricKit's diagnostics beside it. Make the bars give way at zero height.

## Decision
Option 3.
- **An Objective-C exception preprocessor** (`objc_setExceptionPreprocessor`) sees every exception at the throw,
  before anything catches it. When one is thrown on the main thread, `CrashEvidence` writes
  `diagnostics/exception-<UTC time>.json` straight away: name, reason, the stack from the throw down, app and OS
  versions. Then it adds a **workspace dump**, rewriting the same file. The dump holds:
  - each window's frame, full-screen state, key state, the session on screen and the toolbar's per-session
    controls (`run`, `device:<platform>`, `open-in`);
  - each open session's state, focused area, and both areas' panes (front marked with `*`), visibility and frames.

  The bare report is written before the dump is read, so a dump that fails still leaves the reason and the stack.
- **The report is provisional.** If the process is still running 10 seconds later, the exception was caught and
  handled, and the file is deleted. At most one report is written per 10-second window, so a burst of handled
  exceptions costs one write. Normal use in Clinic Dev writes nothing.
- `NSSetUncaughtExceptionHandler` still records an exception nobody catches, on any thread.
- **MetricKit:** a subscriber writes every `MXDiagnosticPayload` it is handed (crashes, hangs, CPU and disk-write
  exceptions) as `diagnostics/metrickit-<time>.json`. A hang like the 7-second freeze before the second crash is
  the kind of thing it reports.
- `DiagnosticsArchive` (ClinicCore, Foundation only) names the files so they sort by time and keeps the newest 30.
- **Settings ▸ Advanced ▸ Diagnostics** gains *Crash reports: Reveal in Finder*.
- **The pane host's bars yield.** The tab strip's 34 pt height and the Run pane's header and failure-bar heights
  are `required − 1`. When a pane has no room yet they give way, instead of AppKit breaking a constraint and
  logging it. At full size they are exact.
- `-ClinicRaiseInLayoutAfter <seconds>` throws from inside a window layout pass, to check all of this end to end.

## Consequences
- The next layout-loop crash leaves a file naming the exception, the throw stack and exactly what each window
  showed. The loop of 2026-10-17 is still not diagnosed; this is what will diagnose it.
- Verified in Clinic Dev:
  - With `-ClinicRaiseInLayoutAfter`, the app died with `exit(6)` as before and left a report with the throw
    stack and the session's panes (Claude in the main area, Files at the front of the panel, both frames).
  - A normal run with two sessions, 20 switches and the panel shown and hidden left no file.
  - Opening sessions and toggling the panel logged no constraint conflicts; before the change, opening a session
    did. The strip's chip sits 5 pt inside a 34 pt strip, as before.
- The preprocessor runs for every Objective-C exception the app throws, including ones frameworks catch
  themselves. On the main thread that costs one file write and a dump per 10 seconds at most.
- **Not verified:** that MetricKit delivers payloads to a Developer ID app on this Mac. Delivery comes on a later
  launch and cannot be forced. The folder will show it.
- The dump reads model state from inside a throw, usually mid-layout. It only reads; if a read itself traps, the
  bare report is already on disk.
