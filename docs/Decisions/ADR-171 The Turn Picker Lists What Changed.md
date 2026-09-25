---
status: accepted (built 2026-09-25)
date: 2026-09-25
amends: "[[ADR-080 Diff Panel]] (the Turn scope's secondary control), [[ADR-170 The Diff Panel Follows The Last Change]] (its menu)"
tags: [adr, git, diff, panel, ui]
---
# ADR-171: The turn picker lists what changed, in words

## Context
User (2026-09-25), after [[ADR-170 The Diff Panel Follows The Last Change]]: *"This is better, but the diff drop
down for turn still shows a ton of junk that doesn't display anything. Can we improve this UX"*

The recorded turns show what that junk was. In the last four sessions of this repo:
- **Most rows led nowhere.** A question, a *commit and push*, a *yes*: each of these turns ends with the tree
  it started with. ADR-170 marked them *no changes*, but they were still half the list.
- **Some rows were tags, not words.** Claude Code submits a prompt of its own when a background task finishes
  (`<task-notification>`) or a subagent hands back (`<agent-message from="…">`). The first line of such a prompt
  is the tag, so the tag became the turn's label, even though these turns often did the work: two of the four
  sessions had changes only in them.
- **The labels that were words did not tell turns apart.** *Lets do it* and *yes* say nothing. A `Menu` item has
  one line, so the counts and the time were crammed after the prompt, where a long prompt pushed them off the
  end.

## Decision
- **The picker is a popover of `PopoverMenuRow`s** ([[ADR-123 Toolbar Choices Open In Popovers]]), scrolling
  past 460 pt. Each row has two lines: the label, then `#12 · +40 −3 · 4 files · 2h ago`, or `running`. The icon
  says who started the turn: a speech bubble for the user, a terminal for a background task, two people for a
  subagent. The `+n` and `−n` take the header's green and red, and drop the colour on the highlighted row, where
  green and red would sit on the accent fill (`PopoverMenuRow.styledSubtitle`). *Latest changes* heads the list, with the turn it resolved to as its subtitle (`Showing #9`).
- **Only turns that changed something, and the running turn, are listed**
  (`SessionSnapshots.withChanges`). Below them, a checkbox reads *Show N turns that changed nothing*. When it is
  checked, those turns appear greyed out and cannot be picked, since there is nothing to show. The choice lasts
  as long as the panel does.
- **Turns the harness started get a sentence.** `TurnSnapshot.origin` reads the tag. A background task's label
  is its `<summary>` (e.g. *Background command "make build" completed (exit code 0)*), kept in a new optional
  `detail` field when the turn is recorded. A background-task turn recorded before this change reads
  *Background task finished*, and a subagent's reads *Subagent reported back*.

## Consequences
- The popover sizes itself, where a `Menu` would size to its longest label, so a long prompt truncates within
  the row instead of widening the list.
- `detail` is optional in the JSON, so snapshot files written before this change decode unchanged.
- A turn a subagent started is labelled by what started it rather than by what it did. The subagent's report
  is long, and its first line is boilerplate. The counts are what set such turns apart.
