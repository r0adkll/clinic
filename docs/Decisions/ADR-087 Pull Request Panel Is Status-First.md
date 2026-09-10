---
status: accepted
date: 2026-09-08
supersedes: the page layout in ADR-053
tags: [adr, github, ui]
---
# ADR-087: The pull request panel leads with what is blocking, not with four tabs

## Context
[[ADR-053 Pull Request Page]] gave the PR panel a three-row header, a segmented picker, and four
tabs — Overview, Checks, Timeline, Files. Using it exposed four problems:

- **~120 pt of chrome before any content**, in a panel that is 380–635 pt wide.
- **The verdict was scattered.** "Can I merge this, and what is stopping me" lived in three places:
  the coloured glyph in the header, the Checks tab, and a metadata grid at the *bottom* of Overview
  that printed raw GraphQL enums — `blocked`, `unstable`, `dirty`, `review_required`. The panel had
  the answer and made the reader assemble it.
- **Overview led with the PR body**, the least actionable thing on the page.
- **"Send to session" was buried in a menu**, and every item was disabled unless the sidebar mark
  matched that item exactly. The one thing this panel can do that github.com cannot was the hardest
  thing in it to reach, and it second-guessed the user about which prompt they were allowed to send.

User (2026-09-08), on being shown three directions: status-first single scroll.

## Options
1. **Keep the tabs, rebuild the header.** Cheapest; leaves the reader clicking a tab to learn whether
   CI is green.
2. **Action-led triage** — the panel becomes a queue, everything else demoted to a reference strip.
   Assumes you open github.com for real reading, which gives up the panel's reason to exist.
3. **Status-first single scroll.** Chosen.

## Decision
- **`PullRequestStatus` (ClinicCore) holds the judgement.** Pure data over a `PullRequest`: ordered
  `Line`s (tone, symbol, text, detail), one optional `Action` (title, symbol, prompt), `canMerge` and
  `mergeBlockedReason`. Every enum is translated at this layer — `DIRTY` becomes "Conflicts with
  main", `BEHIND` becomes "Behind main". Being pure makes the wording a unit test rather than a
  screenshot; 13 cases cover it.
- **Four tones, not a severity number.** `blocking` stops the merge, `waiting` resolves itself or is
  someone else's turn, `good` is settled, `neutral` is context. Lines sort blocking → waiting → good
  → neutral, stable within a tone so the reading order stays checks → merge → review → comments.
  **Draft is pinned above the sort**: it reframes every line under it — "all checks passed" means
  something different on a draft — so it cannot sit at the bottom with the footnotes.
- **One suggested action, same precedence as the mark**, so the panel's headline button and the
  sidebar glyph can never disagree: failing checks → conflicts → review/comments → (draft) review.
  It is a prominent button, not a menu item. The full prompt menu stays alongside it with *nothing
  disabled* — the headline is a shortcut for the likely ask, not a restriction on what may be asked.
- **Layout**: compact two-line header (title + actions; state, number, author, `head → base`), then
  the status block and the buttons, then collapsible **Description / Checks / Conversation / Files**
  with counts. Description opens by default, and so does any section the status block calls out as
  blocking — a failing build is a scroll away, not a click. `gh pr diff` still costs a round trip, so
  Files fetches when it is first opened.
- **The raw-enum grid is deleted.** `mergeable`, `mergeStateStatus` and `reviewDecision` now reach the
  reader only as sentences.
- **An approving review no longer counts as an unanswered comment.** It is somebody else's newer
  comment by the letter of the old rule, but nothing is being asked of the author; counting it made a
  PR read as "Approved by X" and "1 unanswered comment" at once. The rule now lives once, in
  `PullRequestStatus.unansweredComments`, and `PullRequestMark` calls it — which also fixes the
  sidebar summary saying "1 unanswered comment" when someone had simply approved.

## Consequences
- The tab picker, the `Section` enum behind it and the metadata grid are gone. `MarkdownText`,
  `DiffView`, `PRChip`, `PRMarkView` and the mark are untouched.
- `PullRequestMark` and the panel now share one definition of "outstanding", so [[ADR-053 Pull Request Page]]'s
  precedence list has exactly one implementation.
- Verified against live `gh` data for six real PRs (open, draft, merged, conflicting) and on screen in
  a smoke instance.
- Still not done, from ADR-053: full GFM (tables, alerts, `<details>`), image diffs, and posting a
  review from Clinic. Check *failure output* is not fetched either — the status block names the
  failing jobs but cannot yet say why they failed, which is the obvious next thing this layout wants.
