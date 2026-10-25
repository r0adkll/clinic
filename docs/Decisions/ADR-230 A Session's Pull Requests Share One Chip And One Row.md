---
status: accepted (built 2026-10-25)
date: 2026-10-25
supersedes: "[[ADR-228 The Footer Shows The Session's Pull Requests]] (a chip per PR, the newest three, and `+N` for the rest)"
amends: "[[ADR-156 Sessions Can Be Cards]] (several open PRs are one child row), [[ADR-163 A Pull Request Knows Its Stack]] (a branch chain is drawn as a stack; GitHub's stack still decides the merge)"
tags: [adr, ui, footer, sidebar, cards, pr]
---
# ADR-230: A session's pull requests share one chip and one row

## Context
User (2026-10-24): *"How we handle sessions with multiple PRs is not ideal. The card in the session list gets
bloated with PR lines, the bottom session bar doesn't organize them well with split chips and then a menu for
overflow (this is okay, but I think could be better)."*

The worst case was a real Campfire session: seven PRs chained onto main, each targeting the branch of the one
below (#1314–#1320), plus a fix (#1321). Five had a failing check. On the card (ADR-156), each open PR was a
child row, failing ones sorted first. So the card showed three PR rows and *6 more*, and a running subagent
was folded out of sight. The footer (ADR-228) showed the newest three (#1319, #1320, #1321) and `+5`, with
nothing saying the seven were one stack. GitHub reports no stack for that chain (`stack` is null). Only
#1296–#1301 in another session was GitHub stack #1302.

Three directions were mocked on a canvas from those two sessions
(https://claude.ai/artifact/ST1L7mBorZWdmEEPsuGf43), each with a card and a footer:
- **A**: a row and a chip per stack.
- **B**: one summary row and one chip, each opening a tray.
- **C**: glyph trains, one glyph per PR.

I recommended B for the card and C for the footer. In Grill round 1 the user chose **B for both**. They
chose to group branch chains as stacks, and accepted how merged layers and finished PRs are shown. The
question about running out of footer room fell away with a single chip.

## Decision
- **Two or more PRs share one footer chip**: the aggregate glyph (ADR-053's rule: an open one's attention
  wins) and *8 PRs* (*MRs* on GitLab), with a tooltip tally (*8 pull requests: 5 failing · 1 merged or
  closed*). It is accent while any of its PRs is in front, and outlined while one is open behind another
  pane (ADR-228's states). A click opens the tray. A session with exactly one PR keeps ADR-228's chip, which
  opens the PR directly.
- **The tray** (`PRTray`) is a popover listing every PR of the session:
  - each stack with an open layer first, headed *Stack of 7 onto main*, top layer first as GitHub draws a
    stack, with a hairline joining the layers' glyphs;
  - then *Open*, the PRs on their own;
  - then stacks that have fully landed;
  - then *Merged and Closed*;
  - newest first within each group.

  A row shows the glyph, the reference, the title and what its checks or reviews say (*1 check failing*,
  *2 unanswered comments*) in the attention's colour. The PR in front is washed in the accent. A click opens
  the PR the way the chip did (⌥-click beside Claude), and the context menu has Open / Copy URL / Refresh.
  The tray scrolls only past 480 pt.
- **A stack keeps its merged layers in place**, as purple merged glyphs, so it shows how far it has landed.
  Finished PRs that stand alone are listed under *Merged and Closed*.
- **On the card, two or more open PRs are one child row**: *7 pull requests · 5 failing · 1 running*, with
  the aggregate glyph. Its status is *failed* if any open PR's checks fail, else *running* if any are
  pending, else quiet, so it ranks among the other children and Automatic still promotes on it. A click
  opens the same tray beside the row; choosing a PR goes to the session and opens it there. The row counts
  open PRs only. One open PR keeps its own row, and with none open there is no row: the header badge
  carries them, as before.
- **What counts as a stack** (`PullRequestGroup.grouped`, ClinicCore):
  1. GitHub's stack where it reports one (ADR-163), by position.
  2. Otherwise a branch chain: PRs in one repository where one's base is exactly one other's head.
  3. A PR joins the layer under it only when nothing else in the session sits on that layer too, so a fork
     starts its own groups instead of drawing a tree as a list.
  4. A PR not read yet stands alone until it loads.

  Grouping is for display only. The merge box still trusts GitHub's stack alone: a chain is not a stack to
  GitHub, which merges each layer on its own.
- **`PullRequestTally`** (ClinicCore) counts open, failing, running and finished for the row and the tooltip.
  As in ADR-228, a PR not read yet counts as open.

## Consequences
- The card never grows by more than one row however many PRs a session opens. A subagent or run is no
  longer folded away behind PR rows.
- The footer chip has a fixed width, so the working directory has more room.
- Reaching a particular PR from the footer is two clicks instead of one, except in a session with only one
  PR. Its state is still on the chip as the aggregate mark and in the tray at a glance. This was the trade the
  user chose over glyph trains.
- ADR-163 rejected inferring a stack from branch names because GitHub answers the question directly. For
  hand-built chains GitHub has no answer, so the inference is back, for drawing only.
- Checked in Clinic Dev against the two real sessions. Their transcripts were copied into an isolated
  `CLAUDE_CONFIG_DIR`, their attached PRs seeded, and Claude's API pointed at a closed port.
  - The card read *7 pull requests · 5 failing* with *failed ✕*.
  - The footer read *8 PRs*.
  - The tray listed *Stack of 7 onto main* (#1320 down to #1314) and #1321, which had merged, under *Merged
    and Closed*.
  - The other session read *6 PRs*. Its tray showed GitHub stack #1302 as *Stack of 4 onto main*, all
    merged, then #1306 and #1295 under *Merged and Closed*.
  - The card's tray first drew every title grey: a popover takes its presenter's environment, and the
    sidebar's foreground style came with it. The tray now sets `Color.primary` itself.
- 10 tests pin the grouping and the tally (`PullRequestGroupTests`, `PullRequestTallyTests`).
