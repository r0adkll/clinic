---
status: accepted (⌘1–9 and ⌘W amended by ADR-220)
date: 2026-09-07
superseded-by: "[[ADR-220 The Keyboard Reaches Tabs And Sessions]] (⌘1–9 pick tabs; ⌘W closes the focused tab)"
tags: [adr, ui]
---
# ADR-036: Keyboard Shortcuts

## Decision
App-level, hard-coded in milestone 1: Cmd+N new session, Cmd+T new shell tab in current project, Cmd+W close tab, Cmd+Shift+] / Cmd+Shift+[ next/previous tab, Cmd+1…9 jump to tab, Cmd+, preferences (milestone 2), Cmd+Q quit. The same chords are unbound inside surfaces ([[ADR-034 Ghostty Config Overrides and Shell Integration]]). Rebinding is milestone 2+.
