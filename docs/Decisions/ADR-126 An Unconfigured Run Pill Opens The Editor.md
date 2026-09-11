---
status: accepted
date: 2026-09-11
amends: ADR-122 (the toolbar button with no configurations)
tags: [adr, ui, runs]
---
# ADR-126: An unconfigured Run pill opens the editor

## Context
User (2026-09-11): *"Let's set the run placeholder text to just "Run..." and when the user clicks on
it it should just open the edit configuration dialog instead of the quick search panel. The "setup
with claude" button could use some pizzaz with an icon too"*

[[ADR-122 Projects Have Run Configurations]] gave the empty pill the words *Set Up Run…* and sent
its click to the picker sheet. Two things were wrong with that:
- **The picker has nothing to pick.** With no `run.json` it is a list of detected candidates over a
  search field — a chooser opened on an empty choice, when what the click means is *I want to set
  this up*.
- **The words describe the sheet, not the button.** A toolbar control is read as a label for what it
  does; the rest of the toolbar says *Open In*, not *Choose Something To Open In…*.

## Decision
- **The empty pill reads `▶ Run…`** in secondary ink. The ellipsis carries the same promise as any
  menu item: a click asks a question before anything runs.
- **Its click opens the editor sheet** (*Run Configurations*), where a configuration is written.
  The chevron still opens the popover, so detection, IDE import and *Set Up with Claude…* are one
  press away, unchanged.
- **The editor's empty state leads with a prominent `✨ Set Up with Claude…`** — bordered-prominent,
  large, with the sparkles that mark Claude's other actions. It was a plain text button among
  descriptions, the least visible thing on a screen whose whole job is to offer it. Everywhere else
  the action already carried sparkles ([[ADR-122 Projects Have Run Configurations]]); this was the
  one place it did not.
- **And it is only as wide as it reads.** The configured pill is a fixed 196 pt so its name and
  clock do not shuffle the toolbar as a run starts and stops; *Run…* has nothing to hold still for,
  so the empty pill sizes itself — about 115 pt, the scale of the caffeine and Open In capsules
  beside it. User (2026-09-11): *"Can we make this pill smaller when there are no run
  configurations?"*
- **Once a configuration exists nothing changes**: the pill wears its icon and name
  ([[ADR-125 The Icon Picker Browses Every Symbol]]) and runs it, and the picker keeps its own place
  under ⌃⌘R and *Choose Configuration…*.

## Consequences
- `RunToolbarControl.primary` opens `.edit` rather than `.choose` when nothing is selected; the
  label falls back to *Run…*. The pill keeps its fixed 196 pt, so the toolbar does not move as
  configurations appear.
- The picker sheet is now reached only when there is something to pick: the chevron's *Choose
  Configuration…*, ⌃⌘R, and the Run menu.
- **Deferred**: the editor still opens on its empty state rather than pre-selecting a detected
  candidate; detection stays a list the user picks from.
