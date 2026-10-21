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

Built first with ADR-190's full text kept. With four long buttons that alert ran past NSAlert's narrow layout
and came up wide, the buttons in a row. User: *"Maybe have the dialog as a vertical list of buttons (like
before)"*. A probe found the rule: NSAlert stacks its buttons in the 260 pt layout while the alert stays under
about 430 pt tall. That is about 240 characters of text beside four buttons and 300 beside three, whatever
the screen. Past that it switches to the wide layout. An accessory view forces the wide layout too, which is
why ADR-190's popup sheet was wide.

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
- **They stack, so the asking text is brief.** `WorktreeExitFacts.askingText` is one line on where Claude
  runs, the summary, and *Remove deletes the worktree and its branch for good.* Names longer than 24
  characters are shortened in the middle. The worst case is about 205 characters and 400 pt tall, so the four
  buttons always stack. The Background sentence is left out when asking; the other sheets keep it.
- **Every answer is red, since each ends the session.** User: *"Is it possible to colorize the Close actions
  in the dialog? Like make them Red to emphasize their destructive actions?"* The second answer has
  `hasDestructiveAction`: red text on a red tint. The default answer cannot have it, because AppKit would take
  Return off it. Red title text on it does not work either: NSAlert resets the default button's title colour.
  So it gets `bezelColor = .systemRed` and is a solid red button that Return still presses. *Background* and
  *Cancel* stay plain. The same holds for the single *Close* or *Stop* button when the setting does not ask.
  First built with only a non-default Remove in red.
- **A clean worktree is not asked about.** It has nothing to lose, so under Ask it takes the default answer.
  Close shows the plain sheet (*Close*, *Background*, *Cancel*) saying what will happen. Stop no longer shows
  a sheet for it at all. `WorktreeExitFacts.answersToOffer(setting:askDefault:)` decides what the sheet
  offers: both answers, or the single one to take.
- **Quit still keeps under Ask**, whatever the default. Nobody is asked at quit, and a kept worktree can be
  trashed later from Archive, as ADR-190 said.
- Archive is unchanged. A worktree answered on the close sheet under Ask, or taken by default because it
  was clean, is not offered for the Trash again ([[ADR-065 Repo Upkeep]]'s offer is still its own setting).

## Consequences
- `WorktreeExitTests` cover the offered answers, both orders, the stored default's parsing, and the asking
  text's length with long names.
- Larger system text makes the alert taller; at a large enough size the buttons go back to a row. The rest
  still works, just laid out wide.
- Checked in Clinic Dev on 2026-10-21 against a real worktree holding an uncommitted file and a commit of its
  own. The session was started in the worktree and given a state with a synthetic `SessionStart`, since the CLI's
  trust dialog defaults to *No* on this machine. With default Remove, the sheet's default button (read by
  accessibility) was *Close and Remove Worktree* and pressing it closed the tab. With default Keep, Keep
  came first and Remove second in red. After the brief text, the sheet came up 260 pt wide with the four
  buttons stacked, the default on top. With the red answers, a capture of Clinic Dev in front showed the
  default solid red and the other answer red on a tint, and accessibility still named the default button.
  An inactive window draws the default button plain, as AppKit always does. The CLI's own exit dialog was not part of that run; the digit
  watcher that answers it is ADR-190's and unchanged.
- No new smoke key: the run used ADR-166's `-ClinicSessionOnLaunch` with the settings passed as launch
  arguments.
