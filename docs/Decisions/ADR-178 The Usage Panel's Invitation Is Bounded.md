---
status: accepted
date: 2026-10-02
amends: "[[ADR-051 Usage Panel]] and [[ADR-162 Plan Usage Comes From The Status Line First]] (the unconnected panel's explanatory text)"
tags: [adr, ui, usage, bug]
---
# ADR-178: The usage panel's invitation is bounded

## Context
User (2026-10-02), on first using Clinic Dev ([[ADR-176 Clinic Dev Is A Separate App]]): *"the dev app
crashed and was behaving wonky"*

The system log had the cause. After the sidebar was hidden and shown, AppKit reported `-layoutSubtreeIfNeeded
… has continued for 300 iterations`, then raised `NSGenericException`: *the window has been marked as
needing another Update Constraints in Window pass, but it has already had more … than there are views in the
window*. The app hung for seconds and died.

Reproduced by pressing *Hide Sidebar* then *Show Sidebar* through the accessibility API:

| Tab open | Usage panel | Result |
|---|---|---|
| none | unconnected, shown | survives |
| shell or session | unconnected, shown | crashes on Show Sidebar |
| shell or session | hidden (`-ClinicShowUsage NO`) | survives |

It is independent of the hook transport and of the flavor: the stock build survives only because its usage
panel was hidden in the test. The real app never showed it because its usage panel has been connected for
weeks. A new install has exactly the failing state, so this was a first-run crash.

The unconnected panel shows a paragraph with `.fixedSize(horizontal: false, vertical: true)`. While the
sidebar animates open from zero width, that text is measured a character wide and asks for thousands of
points of height. The column's required height then exceeds what the window can give, and the window's
constraints never settle.

## Decision
- The paragraph takes `.lineLimit(6)` before `fixedSize`. Six lines hold the longer message at the sidebar's
  minimum width of 220 pt, and its height is bounded at any width.
- No other sidebar view fixes an unbounded text vertically; the grep is in the log.

## Consequences
- Verified in Clinic Dev: with a shell tab, and with a live session on the mod transport, two rounds of
  Hide Sidebar and Show Sidebar leave the app running, where one round crashed it before.
- Not seen by eye: the paragraph at the minimum sidebar width.
- A fixed-height text in a column that can animate to zero width is the pattern to avoid.
