---
status: accepted (built 2026-10-18; a chip per PR and `+N` superseded by ADR-230)
date: 2026-10-18
amends: "[[ADR-213 The Plus Menu Replaces The Openers]] (a session's PRs are one click away again), [[ADR-216 The Footer Returns Under Both Areas]] (the footer holds PR chips, though still no openers)"
tags: [adr, ui, footer, pr]
---
# ADR-228: The footer shows the session's pull requests

## Context
[[ADR-213 The Plus Menu Replaces The Openers]] took the openers off the main area's tab row, PRs among them, and
accepted that *"a session's PRs are no longer one click from the main row"*. That also took away the one place a
PR's state showed while working in a session: the footer chip ([[ADR-053 Pull Request Page]]) and then the opener
both drew the service's state glyph with its attention dot. User (2026-10-18): *"After our tab/panel refactor I
kinda miss having a quick check / tile for PRs associated with the session. Maybe as small chips next to the
right panel open icon button"*.

Built first beside the panel toggle in the main strip. The user then: *"I'm not sure I'm settled on this
location. Maybe someplace in the bottom status bar?"* The footer ([[ADR-216 The Footer Returns Under Both Areas]])
runs under both areas, has room on its trailing side, and is where the PR chip lived before ADR-212.

## Decision
- **The footer draws a chip per PR of the session**, on its trailing side before the context gauge. The chip is
  `PRChip`: the service's state glyph (ADR-116) and its reference (`#7`, `!482`), with the summary as its
  tooltip and Open / Copy URL / Refresh in its context menu.
- **It rests unfilled and secondary**, like the footer's other controls. It is outlined while its pane is open
  behind another and accent while that pane is in front (ADR-079's states, for PRs only).
- **A click opens the PR the way ⌘⇧P does**: fronts its pane wherever it is open, else opens it in the right
  panel. ⌥-click brings it beside Claude, as ⌥ does for every opener ([[ADR-220 The Keyboard Reaches Tabs And Sessions]]).
- **Open PRs get the chips; merged and closed ones wait behind `+N` while any is open.** User (2026-10-18): *"I
  like being able to see merged prs on sessions, maybe hide them in a menu popup if there are open PRs on the
  bar"*. With none open, the finished ones get the chips instead. A PR not read yet counts as open, so it shows
  rather than hiding until it loads.
- **At most three chips, the newest** (most recently mentioned in the transcript, the order ⌘⇧P uses). The rest
  join the `+N` chip before them.
- **`+N` opens a popover, not a menu**, because a menu cannot draw the service glyph. It lists the open PRs that
  did not fit, then *Merged and Closed*, each with its glyph, reference, title and summary, most recent first. The
  chip itself draws the hidden PRs' aggregate mark (ADR-053's rule: an open one's attention wins), so a failing
  check on a hidden open PR still shows. Every PR is still in `+`'s *Add*.
- **A PR attached with `attach_pr` is kept in Clinic's state**, per session (`ClinicState.attachedPullRequests`),
  and added after the transcript's own on every rescan and refresh. Testing several PRs showed the tool only ever
  patched the in-memory summary, which the next hook-driven refresh rebuilt from the transcript, so an attached PR
  showed for about a turn and a second one never joined the first. Kept like `workItemLinks` (ADR-114), since
  `~/.claude` is read-only (ADR-018). Entries go when their transcript does.
- **The tab strips are unchanged.** Terminal, Files, Diff, Media and Grill do not come back anywhere: ADR-213's
  reasons hold for them, and none has a state worth glancing at.

## Consequences
- A session's PR state is visible again without opening the PR, and one click away.
- A finished PR is still one click from the footer, but no longer takes a chip from a PR still being worked on.
- Stacks (ADR-163) are not grouped: a stack's open layers are separate chips.
- The tab strips keep their whole width for tabs. The footer's working directory truncates first when the
  window is narrow.
