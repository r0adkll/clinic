---
status: accepted
date: 2026-09-09
supersedes: the single-scroll layout in ADR-087
tags: [adr, github, ui, webkit, editor]
---
# ADR-091: Tabs, a file tree, and giving the panel its scroll back

## Context
[[ADR-090 GitHub-Rendered Bodies]] put GitHub's own HTML in the panel and, in doing so, broke
scrolling: `WKWebView` consumes the wheel event, so with the pointer over any body — which is most of
the panel — the PR panel refused to scroll at all.

Three other things surfaced with real use. [[ADR-087 Pull Request Panel Is Status-First]]'s single
scroll of collapsible sections was right for Description and Conversation and wrong for Checks and
Files: both are *browsing* surfaces, and a CI matrix or a 19-file diff behind a disclosure arrow
inside a shared scroll has no room. The file list was a flat `ForEach` of whole-file diffs with no
syntax highlighting, while the editor panel next door (ADR-081) already had a tree and a highlighted
viewer. And the conversation was a stack of detached rounded cards, which gave every comment equal
weight and no sense of sequence.

User (2026-09-09): "the design is lacking and could have a better feel… We should tab the checks and
file content, using a file tree and single file viewer for the later like we do on other screens.
Additionally, the file viewer needs syntax highlighting. Next the webviews eat scrolling gestures."

## Decision
- **Three fixed regions**: identity header, the status block with its actions, then a tab strip over
  **Conversation / Checks / Files**. The status block stays **pinned** rather than becoming a tab —
  ADR-087 exists because "is this mergeable" needed a click, and putting it behind one would undo
  that. Tabs carry counts, and the Checks count takes the tone of the worst check, so a red 7 is
  visible without switching.
- **Files is a tree beside one file's diff**, the editor panel's shape rather than the diff panel's
  continuous scroll (ADR-080). A PR is read file by file, and a nested tree shows the *shape* of a
  change that a flat rail of 19 paths does not. The tree row carries each file's own +/− count.
- **Single-child directory chains are folded into one row.** A PR tree holds only touched paths, so a
  Kotlin project yields `infra/audioplayer/api/src/commonMain/kotlin/com/…` where every level has one
  child — six clicks to reach a file, and a tree made mostly of indentation. Discovered by using it,
  not by reasoning about it.
- **Syntax highlighting reuses `DiffSyntaxHighlighter`** for the selected file only. `DiffFileRows`
  has no public initialiser, so the one-file page goes through `DiffPage.build(files:limit:)`, which
  is also exactly the type the highlighter wants.
- **`PassThroughScrollWebView` forwards vertical scrolling to the panel.** Each body is sized to its
  own content and never needs to scroll itself; a horizontal gesture is kept, because a wide `<table>`
  genuinely does scroll sideways. The direction is decided once when the gesture begins and held for
  its duration, including momentum — deciding per event let a flick a few degrees off-axis change
  owner halfway through and stall.
- **The conversation is a timeline**: avatars on a continuous rail, author and time on one line, body
  below. Avatars come free from the ADR-090 GraphQL call (`author { login avatarUrl }`), keyed by
  login because one person's avatar is the same in every comment.
- **Checks group by workflow**, worst first, each row with a conclusion-coloured leading edge, its
  duration, and a link to the run.

## Consequences
- Two layout rules had to be copied from ADR-080 rather than inherited, because the PR viewer builds
  its own scroll: content width from the monospaced advance (or rows wrap instead of extending), and
  `minHeight: viewport.height` (or a two-axis `ScrollView` centres a short diff in the middle of the
  pane). Both were visible as bugs on the first screenshot.
- `PRStyle.glyphSize` (ADR-089) now also sizes the status-line glyph; the sizes stayed as chosen.
- The tree width is remembered in `ClinicPRTreeWidth`.
- Still open from ADR-087: check *failure output* — the panel names the failing jobs but cannot say
  why they failed, which is the obvious next thing this layout wants.
- Verified on screen against Campfire #1057: all three tabs, the compressed tree, Kotlin highlighting
  in the viewer, the Danger table on the conversation rail, and scrolling with the pointer over a body.
