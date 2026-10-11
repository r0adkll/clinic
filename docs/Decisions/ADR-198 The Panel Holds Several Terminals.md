---
status: accepted (built 2026-10-11)
date: 2026-10-11
supersedes: "[[ADR-079 Panel Tabs]] (at most one pane per kind)"
amends: "[[ADR-046 Terminal Panel]] (one panel shell per tab), [[ADR-056 Session MCP Tools]] (`run_in_terminal` picks an idle shell)"
tags: [adr, ui, panel, terminal, keyboard, mcp]
---
# ADR-198: The panel holds several terminals

## Context
User (2026-10-11): *"1-per panel on session's right-side panels can be too limiting in some circumstances.
For example, my main case is wanting to spool up multiple terminal panels in a session."*

ADR-079 allowed at most one pane per kind, so that a quick action always re-focuses what it already
opened. That suits a view (one Diff, one Media) but not a shell. A dev server in one shell and git in
another is the ordinary case, and the second shell had nowhere to go. ADR-079 deferred multiple shells
and named `PanelPane` as where they would hang. The strip already took arbitrary panes, and the host
already showed whichever surface was in front, since run panes put other surfaces through it
([[ADR-122 Projects Have Run Configurations]]). The single shell lived in one accessor,
`Tab.panelSurface`, and in the code that read it.

The user chose: terminals only for now, but anticipate Files tabs; when `run_in_terminal` finds the shell
busy, open a new one; no splits — larger work on panels and sessions is coming.

## Decision
- **A kind says whether a tab may hold several of it.** `PanelPane.Kind.allowsSeveral` is true for
  `terminal` alone. Files is the next candidate and needs only its case added: the menus, recency and
  numbering below are written against the flag, not against shells.
- **A pane of such a kind is numbered.** `PanelPane.ordinal` is the lowest number no open pane of the kind
  holds, so closing *Terminal 2* frees the name for the next one.
- **The quick action still fronts, and never adds.** ⌘J, the footer chip and *Terminal* in the Panel
  menu front the shell used last, opening one only when there is none. `SidePanel` keeps the order in
  which panes were fronted, and `pane(kind)` returns the most recent of its kind. ADR-079's promise holds:
  the same chord always lands in the same place.
- **New Terminal adds one.** ⌘⇧J (rebindable, *New Terminal Panel Tab*), *Panel ▸ New Terminal*, and the
  strip's `+` menu. That menu keeps a kind that allows several in its *Add* section after one is open,
  labelled *New Terminal*. The chord is Clinic's, so Ghostty's own binding on it yields, as every Clinic
  chord does (`reloadGhosttyKeybinds`).
- **A shell's chip says what the shell says.** A panel shell's OSC title is kept on its pane
  (`shellTitle`) and names the chip, still never the tab (ADR-046). With no title, or when two shells
  report the same one (fish calls every idle shell in a home folder `~`), the chip falls back to
  *Terminal*, *Terminal 2*, …, since a title they share names neither of them.
- **Only the shell on screen is drawn.** `SidePanel.occludeShells` occludes every shell pane except the
  selected one in a visible panel in a tab on screen. The keyboard goes to the selected shell. A shell
  that exits, or asks to close, closes its own pane through `closePane`, so the keyboard follows whatever
  is fronted next, which may be another shell.
- **`run_in_terminal` types only into a shell at its prompt.** `TabStore.idleShell` picks the most recently
  fronted shell with no foreground job (`foregroundJobName == nil`). When every shell is busy, it opens a
  new one. A command an agent sends can therefore no longer land in a running dev server's stdin. The
  tool's description says so, and its result names the shell it used.
- **The session card lists every busy shell**, one row each, labelled with its job and the pane's name,
  and its row fronts that shell.
- **Still deferred:** splits inside a pane, persisted scrollback, moving a shell between tabs.

## Consequences
- `Tab.panelSurface` is gone. `Tab.panelSurfaces` and `Tab.shellPane(for:)` replace it. Anything that
  needs "the" shell must now say which one: the one on screen (`panel.selected`), the most recent
  (`panel.pane(.terminal)`), or an idle one (`idleShell`).
- An agent that keeps starting long-running commands opens a shell for each. That is visible in the strip
  and costs one libghostty surface each. Nothing closes them for the reader.
- The empty panel's Views list is unchanged: with no panes open there is nothing to add beside.

## Verification
`make test` (654 pass) and the Clinic Dev build are clean. Driven live in Clinic Dev with
`-ClinicSeveralTerminalsOnLaunch YES`, a seam that opens a shell tab, runs the steps below, and logs each
step's shells (name, `*` for the front one, occlusion) under `com.r0adkll.clinic` category `smoke`:

| Step | Shells |
|---|---|
| ⌘J | Terminal* |
| ⌘⇧J, ⌘⇧J | Terminal (occluded), Terminal 2 (occluded), Terminal 3* |
| front the first, ⌘⇧G, ⌘J | Terminal*, Terminal 2 (occluded), Terminal 3 (occluded) — ⌘J returns to the shell used last |
| close Terminal 2, ⌘⇧J | Terminal, Terminal 3, Terminal 2* — the freed name is reused |
| fish titles arrive | all three report `~`, so the chips stay numbered |
| `run_in_terminal` × 2 | the first goes to Terminal 2 (idle, most recent); with `sleep 20` running there, the next goes to Terminal, which is idle |
| every shell busy | a new shell opens and takes the command |

Screen capture is declined for this session's process and it is not trusted for accessibility, so the strip
itself was not looked at. To check by hand in Clinic Dev: ⌘J, then ⌘⇧J twice; the strip shows three
terminal chips. Run `npm run dev` (or `sleep 60`) in one and its chip takes the command's title. Then ⌘⇧G,
then ⌘J, and you land back in that shell.
