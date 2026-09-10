---
status: accepted
date: 2026-09-07
supersedes: part of ADR-019
tags: [adr, ui]
---
# ADR-049: Visible tab bar

## Context
[[ADR-019 Window and Surface Lifetime]] hid the tab bar and made the sidebar the only navigation, as Collins does by default. User feedback: open tabs are not visible enough; multiple tabs should be obvious.

## Decision
A tab bar above the terminal lists open tabs (sessions and shells) with state glyph, title and close button; click selects, ⌘1–9 still jump. Shown by default; View → "Show Tab Bar" toggles it. Sessions still open from the sidebar; the tab bar only shows what is open.

## Consequences
- The sidebar no longer carries a "Shells" section; shells live in the tab bar only.
- Tab order = open order; drag reordering deferred.
