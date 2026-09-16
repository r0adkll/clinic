---
status: accepted (built 2026-09-16)
date: 2026-09-16
supersedes: "the card's context wording in [[ADR-157 The Status Line Reports Context]] (\"42% context\") and in [[ADR-156 Sessions Can Be Cards]] (\"85k context\", and no gauge)"
tags: [adr, ui, sidebar, sessions]
---
# ADR-158: The card's meta line gives way, and draws a gauge

## Context
User (2026-09-16), living with the cards of [[ADR-156 Sessions Can Be Cards]]: *"I now have card that has just
a PR in its list, but there is some extra padding at the bottom that shouldn't be there. Also some long
branch names will push the context % offscreen which is not great (also it would be nice to not say
context, but use the progress bar like from the design artifact instead)."*

Three separate causes, all reproduced in a smoke instance: a card with a 63-character branch, only a PR
child, and a status line payload sent to its hook socket; beside it, a closed card with a PR and a recap.
- **The padding** came from the children's hairline. It was a bare `Rectangle` laid out as a *sibling* of
  the child rows, so it was greedy: it took whatever height the list row offered. The line visibly ran
  ~18 pt past the last child. The same greed squeezed the now line above it: a recap allowed two lines
  was cut to one ("… PR is open" → "… P…").
- **The overflow** was a priority inversion. The branch text had `layoutPriority(1)` and everything after
  it had none, so the branch took its full width first and model, effort and context were pushed out.
- **The wording** "42% context" was ADR-157's; the mockup had drawn a small bar.

## Decision
- **The hairline is a `background` of the children's stack**, not a sibling. A background is proposed the
  stack's own size, so the line is exactly as tall as the rows and takes no part in the row's height.
- **Where gives way before how.** The branch (middle truncation) and the folder path (head truncation) have
  the default priority. Model and effort have priority 1 and truncate only after the branch is gone. The
  context gauge has priority 2 and a fixed size, so it is the last thing on the line to lose space.
- **Context is a gauge**: a 26 × 4 pt capsule track in `.quaternary` with a `.secondary` fill, and the
  percentage beside it ("42%"), rounded down as before. No word "context" on the line. The tooltip says
  *42% of the 200k context window used*, and VoiceOver reads *Context 42% used*. Secondary like the rest
  of the line, so on a selected row it follows the label colour. It takes no warning colour near full:
  [[ADR-096 Session Status Indicators]] spends colour on what wants the reader, and a filling window does
  not ask for anything.
- **Without a status line** (an attached session, or before the first report) the fallback is the
  transcript's count as "84k tokens" — a bare number, since there is no window size to draw a bar against.

## Consequences
- Verified in the smoke instance before and after, at full resolution. The hairline ends at the last child,
  the recap wraps to its second line, and the long branch reads *worktree-…rds-layout · Opus 5 · xhigh ·
  ▬ 42%*.
- Any future sibling in the card's stacks that is a bare `Shape`, `Color` or `Spacer` will show the same
  greed; decorations belong in `background`/`overlay`.
