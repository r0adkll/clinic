---
status: accepted
date: 2026-09-08
supersedes: part of ADR-051
tags: [adr, ui, claude, sidebar]
---
# ADR-085: The collapsed usage panel is a snapshot, not a title

## Context
[[ADR-051 Usage Panel]] made the sidebar footer collapsible, but collapsing it threw away every
number: the row became a chevron, the words "Claude usage", the plan name and a refresh button.
So the panel was only useful expanded, where it costs ~110 pt of sidebar — and the sidebar is the
list of sessions, which is what that space is for. In practice the panel stayed open purely to keep
one glanceable fact ("how much of the 5-hour window is left") on screen.

User (2026-09-08): the collapsed state should carry a small snapshot of current usage.

## Decision
- **Collapsed is one row of chips, one per `limits[]` entry.** A chip is a short label, a 24 × 4 pt
  capsule meter, and the percent: `5h ▰▰▱▱ 47%  7d ▰▱▱▱ 45%  Fable ▰▰▰▱ 70%`. The row keeps the
  panel's existing height (~20 pt), so the snapshot is free — it replaces the title, it does not
  add a line. Labels are `Bar.shortTitle`: `5h`, `7d`, and the model's first non-"Claude" word for
  a scoped limit.
- **The whole row is the disclosure control.** Clicking anywhere in it expands to the ADR-051 panel,
  so the snapshot is also the way to the detail. Expanded is unchanged: full bars, reset captions,
  credits, "Updated …".
- **Severity, not accent, does the shouting.** The meter takes the bar's tint (accent normally,
  orange at ≥ 90 % or `severity: warning`, red at `exceeded`) but the *percent stays secondary ink*
  unless the limit is actually pressing. Three accent-coloured numbers in one row read as three
  alarms; with this split a real warning is the only coloured thing in the footer.
- **Reset times live in the tooltip.** Each chip's help is `Session (5h) · 47% · resets in 14 minutes`;
  the row's own help carries the plan and how fresh the numbers are. Nothing in the row changes width
  as state changes, so the footer never reflows under the pointer (the ADR-077 principle).
- **Narrow sidebars drop chips, calmest first.** `UsageSnapshot.compactBars(limit:)` (ClinicCore,
  pure, unit-tested) ranks by severity then percent and returns the survivors *in display order*, so
  an exceeded model-scoped limit outlives a quiet session one. `ViewThatFits` picks the widest set
  that fits: three chips at the 322 pt default, two at 222 pt, one below that. Measured on
  2026-09-08 at both widths.
- **Fallbacks.** Before the first fetch, or when the snapshot has no bars, the row shows the old
  "Claude usage" title; not-connected still shows the ADR-070 Connect button. An error with no
  snapshot puts an orange `exclamationmark.triangle` beside the title, with the message in the
  tooltip.
- Polling is unchanged and runs whether or not the panel is expanded — ADR-051's "poll while the
  panel is expanded" no longer holds, because the collapsed row is now live too. Consent
  ([[ADR-070 Usage Panel Consent]]) still gates everything.

## Consequences
- The footer is worth collapsing, so the default expanded panel stops being the only useful state
  and the sidebar gets ~90 pt of session list back.
- A fourth limit kind would be dropped first on a narrow sidebar rather than breaking the row.
- Chip width is fixed by `minWidth: 24` on the percent, which fits three digits; a limit above
  999 % would widen its chip.
