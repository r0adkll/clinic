---
status: accepted (built 2026-09-14)
date: 2026-09-14
amends: "[[ADR-090 GitHub-Rendered Bodies]] (the Conversation section's laziness)"
tags: [adr, github, ui, webkit, layout, milestone-4]
---
# ADR-148: The conversation is not lazy

## Context
User (2026-09-14): *"I'm experiencing a crash on my desktop-distribution-prep session on Campfire when I
open the PR panel and try to scroll down. It reproduces consistently."*

Opening the PR panel on `r0adkll/Campfire#1103` and scrolling killed the app every time. There was no
crash report — none has ever been written for Clinic — because the app was not dying on a signal. AppKit
was raising an uncaught `NSGenericException`:

> The window has been marked as needing another Update Constraints in Window pass, but it has already had
> more Update Constraints in Window passes than there are views in the window.

352 passes against 346 views. *When there is no `.ips`, the app threw rather than being killed*, and
`/usr/bin/log show` with a per-PID predicate is what recovers it.

The backtrace is not a cause. It shows where the loop **closes** —
`LazyLayoutViewCache.updateItemPhase` → `NSHostingView.requestUpdate` → `setNeedsUpdateConstraints`,
cascading to the window — and is byte-identical whatever opens it. Clinic's own frames appear nowhere in
it except `main`. Two fixes were shipped against readings of that trace, and both were wrong: first
[[ADR-090 GitHub-Rendered Bodies]]'s self-sizing web views (the `ResizeObserver` → `@State height` →
`.frame(height:)` loop), then the sidebar `List`, read out of the `_NSConstraintBasedLayoutHostingView`
in the cascade. Both were reverted in full.

A temporary `prloop` logger — web view creation, teardown and every height report, plus
`onAppear`/`onDisappear` probes on the conversation items and the sidebar rows — settled it in one
reproduction. The four bodies were made once, settled their heights immediately (`24->2116`, `24->200`,
`24->80`, `24->39`) and then reported nothing but `drop` for **17 seconds before the crash**. The sidebar
logged four appearances and no churn. What did churn: at the instant the Danger body took **2116pt**, all
three comments went `CONV-`; on the next scroll they returned and flip-flopped appear/disappear **every
~7ms** until the window gave up.

## Options
1. **Keep the `LazyVStack` and clamp body height.** Caps the symptom, lies about the content, and a
   comment just under the cap still loops.
2. **One document for the whole section** — the remedy ADR-090 itself names for when one web view per
   body bites. Removes the loop and the per-comment cost, but gives up the native comment chrome
   (author, timestamp, review badge) that ADR-090 deliberately kept in SwiftUI.
3. **A plain `VStack`.** Chosen.

## Decision
- **The Conversation section is a `VStack`, not a `LazyVStack`.** A lazy stack cannot settle on a visible
  range when one item is about twice the viewport: realising the body lengthens the content, which pushes
  it out of the band, which unrealises it, which shortens the content, which pulls it back in. There is
  no fixed point, and each flip re-enters `NSHostingView.layout`. A rendered comment routinely *is* that
  tall — a Danger report measures 2116pt against a ~1000pt panel — so this is the ordinary case, not an
  outlier.
- **Laziness was buying little here.** Every body in view is realised anyway, and ADR-090 already accepts
  that a wide-open thread is one web view per comment. What laziness deferred was work inside an
  already-open panel, which is the cheap half.
- **The Checks tab keeps its `LazyVStack`.** Its rows are a fixed small height; the failure needs an item
  taller than the viewport, and a check row can never be one.

## Consequences
- A 50-comment PR builds 50 web views when the panel opens rather than as they scroll into view. ADR-090
  already named that number as the point where **option 2** becomes the answer; this ADR does not spend
  that budget, it just stops pretending laziness was protecting it.
- ADR-090's "the Conversation section is collapsed by default and lazy" is now half true: still collapsed
  by default, no longer lazy.
- *Read a backtrace for where the loop closes, not for what opened it.* Three of the user's reproductions
  went to theories a five-minute probe killed outright. Instrument first when the trace holds none of
  our own frames.
- Verified on screen by the user against #1103: the panel opens and scrolls without dying.
