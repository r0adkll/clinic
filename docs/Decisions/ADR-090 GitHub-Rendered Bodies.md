---
status: accepted (navigation clause superseded by ADR-115)
date: 2026-09-09
supersedes: the "not now" on full GFM in ADR-053 and ADR-087
tags: [adr, github, ui, webkit]
---
# ADR-090: Let GitHub render PR bodies and comments

## Context
[[ADR-053 Pull Request Page]] shipped `MarkdownText`, a hand-rolled block parser — headings, fenced
code, quotes, paragraphs, inline styles via `AttributedString` — and listed "full GFM rendering
(tables/alerts/details)" under **Not now**. [[ADR-087 Pull Request Panel Is Status-First]] repeated it.

That gap is not academic. Sampling the user's real Campfire PRs: **18 raw `<table>` blocks and 21
Markdown tables** across comments, none of which `MarkdownText` can render — Danger posts its report
as literal `<table>` HTML, so Clinic was showing the reader raw tags *and* the `<!-- DangerID -->`
comment block. The test PR (`r0adkll/ditto#1`) adds the other common case: raw `<img>` pointing at a
`user-attachments` GIF, in both the body and a comment.

User (2026-09-09): "For the comments and description we should render all of github's markdown / html
(like images and the like)."

The decisive discovery is that none of this needs a parser. `gh` can return **GitHub's own rendered
HTML** — `bodyHTML` over GraphQL, or `body_html` under `Accept: application/vnd.github.full+json` —
for the PR, issue comments, reviews and review comments alike.

## Options
1. **Extend `MarkdownText`.** Most work, least fidelity, and raw HTML is unreachable in principle.
2. **A native GFM renderer (swift-markdown-ui, under [[ADR-058 Third-Party Packages Allowed]]).**
   Tables, task lists, images, real SwiftUI text selection. But it does not render raw HTML, so the
   Danger tables — the actual motivating case — stay broken, along with `<details>` and `<img>`.
3. **GitHub's HTML in a `WKWebView`.** Exact by construction. Chosen.

## Decision
- **One extra GraphQL call per refresh** (`GitHubService.renderedHTML`) returns `bodyHTML` for the PR
  and for every comment and review, each with its node id. GraphQL rather than REST specifically
  because those ids are the same ones `gh pr view --json comments,reviews` already reports, so
  `PullRequest.applying(_:)` merges by id instead of guessing from author and timestamp.
- **It is a second, non-fatal call.** `bodyHTML` is optional on `PullRequest` and `Comment`; the panel
  renders the Markdown source until it lands and falls back to it if the call fails. A GraphQL error
  must never blank a PR that otherwise loaded, so `MarkdownText` stays as the fallback rather than
  being deleted.
- **Re-fetched on every refresh, never cached.** The image URLs GitHub embeds are signed and expire
  after ~5 minutes; ADR-053's existing 5-minute poll is what keeps them live.
- **The web view is inert.** A CSP of `default-src 'none'` with `img-src https: data: blob:` blocks
  every subresource except images; scripts are restricted to a per-load nonce, so the only JavaScript
  that can run is the height reporter. Link clicks are intercepted and opened in the browser; every
  other navigation is refused outright. Comment bodies are written by strangers, and this is the
  boundary that makes that safe.
- **Height comes back from a `ResizeObserver`**, not a one-shot measurement, because the case that
  matters is an image finishing its download and reflowing the body.
- **Styling is a small stylesheet, not a port of GitHub's.** GitHub's HTML is semantic, so a palette,
  the system font, and rules for tables, code and `.markdown-alert` are enough. GitHub's own custom
  properties (`--bgColor-muted`, …) are defined because it inlines them in `style=` on images.
- **Native chrome is kept.** The author, timestamp and review badge on a comment card stay SwiftUI;
  only the body is HTML.

## Consequences
- WebKit enters the panel. For a native app this is a real concession, taken because fidelity to
  github.com is the whole point of the feature and no native renderer can reach raw HTML.
- **One `WKWebView` per body.** The Conversation section is collapsed by default and lazy, so a long
  thread only pays when opened — but a 50-comment PR opened wide is 50 web views, and if that bites,
  the fix is one document for the whole section rather than one per comment.
- Text selection inside a body is WebKit's, not SwiftUI's; selection cannot span two comments.
- ADR-053's remaining "not now" list loses tables, alerts, `<details>` and images. Still open: posting
  a review from Clinic, and check *failure output* (noted in ADR-087).
- Verified on screen: the ditto test PR (raw `<img>` GIF in body and comment) and Campfire #1057
  (Danger's raw `<table>` report, issue cross-references, a merged-state header).
