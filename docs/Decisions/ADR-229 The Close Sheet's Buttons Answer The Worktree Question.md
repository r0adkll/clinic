---
status: accepted (built 2026-10-21)
date: 2026-10-21
amends: "[[ADR-190 Clinic Answers The Worktree Exit Dialog]] (under *Ask* the sheet's buttons take the answer in place of a popup, a setting picks which comes first, and a clean worktree is not asked about)"
tags: [adr, sessions, git, worktree, ui, settings]
---
# ADR-229: The close sheet's buttons answer the worktree question

## Context
[[ADR-190 Clinic Answers The Worktree Exit Dialog]] asks under *Ask* with a popup in the close (or stop)
sheet, always on *Keep the worktree*, above a *Close* button. Removing took three clicks: open the popup,
pick Remove, press Close. User (2026-10-21): *"For the close/archive dialog that gives us an option for
keeping or removing the worktree. Can we add a setting that allows us to set the default option for that
choice. For example, I want to default to removing the worktree in the prompt. Also, can we improve the UX
here so its less clicks?"*

Checked against AppKit while building: **NSAlert takes Return off a button with `hasDestructiveAction`.**
Its `keyEquivalent` is cleared when the button is added, again by `layout()`, and again by `runModal()`.
The window then has no default button, so Return does nothing. A probe confirmed both resets.

## Options
- **Keep the popup and let a setting pick its starting item.** Removing becomes one click when Remove is the
  default, but the other answer still takes three. Rejected.
- **Fold the default into the main setting** as *Ask, Keep first* and *Ask, Remove first*. One picker, but
  four items, two of them nearly the same sentence. Rejected.
- **Put the answers on the sheet's buttons, the default first, and add a setting that only shows under
  Ask.** Chosen. Either answer is one click, and the default is a Return press.

## Decision
- **A second setting picks the default answer.** `WorktreeExitAnswer.askDefaultKey`
  (`ClinicWorktreeExitAskDefault`, `keep` or `remove`, Keep when unset) is shown as *Default answer* under
  *When a worktree session exits* in Settings → Sessions → *Worktrees*, only while that says *Ask when
  closing*.
- **Under Ask, the answers are the sheet's own buttons.** *Close and Remove Worktree* and *Close and Keep
  Worktree* (*Stop and …* on the stop sheet), the default answer first, so it is the default button and Return
  takes it. Then *Background* where it applies, then *Cancel*, which Escape takes. The popup is gone.
- **A Remove that is not the default is drawn destructive**, in red. One that is the default is drawn as a
  plain default button, because AppKit would otherwise take Return off it. The user chose that default; the
  sheet's text still says Remove deletes the worktree and its branch for good.
- **A clean worktree is not asked about.** It has nothing to lose, so under Ask it takes the default answer.
  Close shows the plain sheet (*Close*, *Background*, *Cancel*) saying what will happen. Stop no longer shows
  a sheet for it at all. `WorktreeExitFacts.answersToOffer(setting:askDefault:)` decides what the sheet
  offers: both answers, or the single one to take.
- **Quit still keeps under Ask**, whatever the default. Nobody is asked at quit, and a kept worktree can be
  trashed later from Archive, as ADR-190 said.
- Archive is unchanged. A worktree answered on the close sheet under Ask, or taken by default because it
  was clean, is not offered for the Trash again ([[ADR-065 Repo Upkeep]]'s offer is still its own setting).

## Consequences
- `WorktreeExitTests` cover the offered answers, both orders, and the stored default's parsing.
- Checked in Clinic Dev on 2026-10-21 against a real worktree holding an uncommitted file and a commit of its
  own. The session was started in the worktree and given a state with a synthetic `SessionStart`, since the CLI's
  trust dialog defaults to *No* on this machine. With default Remove, the sheet's default button (read by
  accessibility) was *Close and Remove Worktree* and pressing it closed the tab. With default Keep, Keep
  came first and Remove second in red. The CLI's own exit dialog was not part of that run; the digit
  watcher that answers it is ADR-190's and unchanged.
- No new smoke key: the run used ADR-166's `-ClinicSessionOnLaunch` with the settings passed as launch
  arguments.
