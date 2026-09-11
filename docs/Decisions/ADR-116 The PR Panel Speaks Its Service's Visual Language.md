---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-089 Pull Request Glyph Sizing]] (the glyph and its optical compensation); amends the drawing of [[ADR-087 Pull Request Panel Is Status-First]] and [[ADR-091 Pull Request Panel Tabs and Files Tree]]"
tags: [adr, ui, github, gitlab, icons]
---
# ADR-116: The PR panel speaks its service's visual language

## Context
User (2026-09-10): *"Let's take a UI/UX design improvement pass at the PR panel. We should leverage
more visuals for w/e the service is (i.e. Github, Gitlab)"*.

The panel was Clinic chrome with GitHub's data poured into it. The only sign of the service was a
Safari button. Every glyph was a generic SF Symbol, the state colours were the system's (`.green`,
`.purple`) rather than GitHub's, and the words were fixed ("PR #7", "Merge (squash)"). A GitLab merge
request, once Clinic can load one ([[ADR-113 Work Item Providers and Sources]]), would have been
drawn exactly like a GitHub PR and called one.

A mockup put today's panel beside a GitHub version and a GitLab version of the same layout. The user
chose all three recommended answers:
- **How far**: the full pass. Not only the mark, glyphs, colours and words, but also the service's own
  components (merge box, tab idiom, comment boxes).
- **Glyph reach**: everywhere. The sidebar, the footer chip and the panel tab take the service glyph
  too.
- **GitLab**: visuals ready, no data. Loading merge requests with `glab` is its own piece of work.

## Decision
### Identity is a value, not a branch
- **`CodeHost` (ClinicCore)** is derived from a ref's host: `gitlab` when any label of the host is
  `gitlab` (gitlab.com, `gitlab.example.com`), otherwise `github`, because `gh` reads it and an
  Enterprise host can be called anything.
- It carries the **words**: noun, abbreviation, sigil (`#7` / `!482`), pane titles
  (Conversation · Checks · Files changed / Overview · Pipelines · Changes), merge button and
  method titles, auto-merge verbs, and the header sentence ("wants to merge 3 commits into `main`
  from `feature`" / "requested to merge `feature` into `main`"). They are unit tests.
- **`ServiceArt` (app)** carries the **glyphs and palette** for each host, light and dark:
  Primer's colours and Octicons for GitHub, Pajamas colours and GitLab's icons for GitLab. The panel
  asks the host; it never checks "is this GitHub".

### One rule for colour
**Facts about the PR wear the service's colours; anything that types into the session wears Clinic's
accent.**
- The state pill, merge-box discs, check glyphs, counters, tab underline and merge button use the
  service palette.
- The headline "Fix the failing checks" and the Send menu use the accent, and sit outside the merge
  box.
- So "this talks to Claude" and "this talks to GitHub" never look alike. Colour carries information
  here, like the Tasks label capsules ([[ADR-112 Tasks Screen]]), so varying it by service does not
  break the accent-tile rule of [[ADR-111 Nav Rows Wear Accent Tiles]].

### The panel
- **Service strip.** The service's mark and `owner / repo` sit above the title. "Open on GitHub"
  wears the mark instead of Safari's compass.
- **Identity.**
  - The title is followed by the reference.
  - The state pill is drawn the service's way: GitHub fills it with white on top, GitLab uses a
    soft wash.
  - Then the author's avatar and the merge sentence with branch pills.
  - A second row holds the labels in their repository colours (reusing `LabelCapsule`), reviewer
    avatars with a badge for the verdict that stands, and GitHub's five-square diffstat.
- **The status block is the merge box.**
  - It shows the same `PullRequestStatus` lines in the same order (ADR-087 is unchanged in
    substance). Each line sits on a disc of its tone, with a glyph chosen by what the line is about.
  - A line that stands for checks lists them inline with their CI provider's mark. It starts open
    when blocking and holds six checks, then "N more in Checks". While open, it replaces the
    line's list of names.
  - The merge button is a split button in the service's merge colour. The method is picked per
    merge from its menu, as on github.com, and the Settings value stays the default.
- **Tabs** use the service's idiom: glyph, name and counter, with the selected-tab underline. As the
  panel narrows they fall back to names only, then glyphs only.
  - The Checks counter now shows **what is failing**, or failing that what is running, and only
    then the total. [[ADR-091 Pull Request Panel Tabs and Files Tree]] showed the total in the worst
    tone, but the number worth reading is the failing one.
- **Timeline.**
  - Comments sit in bordered boxes with a header strip and Author / bot pills. The opening post is
    outlined in the link colour.
  - Reviews are events on the rail: a disc with the verdict. A review that has a body gets a box
    under the event.
  - The rail is drawn as each row's background, so consecutive rows join into one line.
- **Checks rows** show the status glyph, the provider mark, the name, and "failed · 2m 14s" or the
  duration, with the link-out on hover.
  - ADR-091's conclusion-coloured leading edge is gone. The service's status glyph now carries that.

### What the data needed
- `gh pr view --json` adds `labels`, `reviewRequests` and `commits`, so there is no new round trip.
- `PullRequest.reviewers` folds reviews into one verdict per person:
  - An approval or request for changes stands until replaced. A later plain comment doesn't
    withdraw it.
  - A dismissed review drops back to "commented".
  - The author is never listed.
  - Outstanding requests come last.
- A GitHub App author is a bot. `gh pr view` spells it `app/dependabot` and GraphQL spells it
  `dependabot`, so `Author.isBot` counts the `app/` prefix and avatars are matched on GraphQL's
  spelling. Before this, such an author was labelled "Author" and had no avatar.
- **`CheckProvider` (ClinicCore)** reads who ran a check from where its link points:
  - `/actions/runs/` means GitHub Actions.
  - CircleCI, Buildkite, Vercel, Netlify, Travis, Bitrise, Codecov, SonarQube Cloud, Jenkins and
    GitLab CI are recognised by host.
  - A non-empty workflow name means Actions when the link says nothing.
  - Anything else is "External check", drawn as a dotted circle.

### The glyph everywhere (supersedes ADR-089)
- `PRGlyph` draws the PR's **state** in the service glyph and colour: open, draft, merged, closed.
  **Attention becomes a corner dot** in the tone of `PullRequestMark.attention`, via the new
  `attentionTone`: red for blocking, amber for waiting, green for approved.
- An open PR with failing CI therefore still reads as an open PR, with a red flag on it. ADR-089's
  per-attention SF Symbols (`xmark.octagon`, `exclamationmark.bubble`…) made every problem look like
  its own kind of object.
- The dot is **cut out** of the glyph rather than ringed in a background colour, so it reads the same
  on the sidebar, the footer bar and a selected chip.
- It is used by the footer chip (which now reads `#7`, not `PR #7`), the sidebar row, the panel tab,
  the panel's Add/Open menus, and the Tasks screen's linked-PR chips.
- ADR-089's optical compensation for `arrow.trianglehead.pull` no longer applies. The Octicons and
  GitLab glyphs fill a 16 pt grid, so `PRStyle.glyphSize` is retuned: chip 14, sidebar 12, tab 12,
  compact tab 14. The general lesson of ADR-089 still holds: sizes are chosen, not inherited.

### Assets
- `scripts/vendor-service-icons.sh` fetches the glyphs, pinned by version, into
  `Assets.xcassets/Service` as template SVG imagesets (63 in total):
  - Octicons 19.36.0 (MIT), GitHub's set and the GitHub mark;
  - GitLab SVGs 3.164.0 (MIT);
  - Simple Icons 16.30.0 (CC0), the GitLab mark and the CI provider marks.
- The output is committed, and re-running the script reproduces it.
- Logos are used only to name the service, which both brands' guidelines allow.

## Consequences
- Adding GitLab merge requests is now a data problem only:
  - parse `/-/merge_requests/<n>` refs;
  - a `glab`-backed service behind the same `PullRequest` model.

  The panel, the words and the art are ready. `PullRequestStatus` prompts still say "PR #n" and need
  the host's words when that lands.
- `PRStyle` lost its colour functions (`color`, `checkColor`, `checkSymbol`, `tint`). `ServiceArt`
  owns all of it. `PullRequestMark.symbolName` is still computed and tested, but nothing in the app
  draws it now.
- The header is taller than ADR-091's two lines: strip, title, sentence, labels row. It is still
  pinned with the merge box, so on a short panel the pane below has less room. Inline check lists
  cap at six rows for that reason.
- 13 new ClinicCore tests: host detection and vocabulary, merge sentence, check providers,
  reviewers, diffstat, the new fields, App authors, and attention tone.
