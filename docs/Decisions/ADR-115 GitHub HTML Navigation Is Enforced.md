---
status: accepted
date: 2026-09-10
supersedes: "[[ADR-090 GitHub-Rendered Bodies]] (its navigation clause: in-page anchors now scroll instead of being sent to the browser)"
tags: [adr, github, webkit, security]
---
# ADR-115: GitHub HTML navigation is enforced

## Context
[[ADR-090 GitHub-Rendered Bodies]] says link clicks in a rendered body open in the browser and every
other navigation is refused. That policy **never ran**, from the day it shipped until this ADR.

`GitHubHTMLView`'s coordinator declared `webView(_:decidePolicyFor:decisionHandler:)` with a plain
`(WKNavigationActionPolicy) -> Void` handler. WebKit's requirement is `@MainActor @Sendable`, and
under Swift 6 a near miss is a different method. The compiler said so ("nearly matches optional
requirement"). WebKit, finding no policy method, allowed everything. Clicking a link in a PR
comment loaded that page inside the comment's small web view.

This surfaced while building the Tasks thread ([[ADR-112 Tasks Screen]]). Declared with the correct
signature, the same policy *did* run, and it cancelled the page's own `loadHTMLString`: its "the view
has no URL yet" test fails because the web view has already adopted the base URL by the time it asks.

## Decision
- **One policy, `GitHubHTMLNavigation.decide`, shared by every view of GitHub's HTML** (PR bodies and
  the Tasks thread). Both delegates call it with the exact WebKit signature, and a comment on the
  type says what happens if the signature drifts.
- **The initial load** is recognised by what it is: an `.other` navigation to the base URL
  (`https://github.com/`), or `about:`. It is not recognised by the view's URL.
- **A link to an anchor in the same document** (`#user-content-…`, which GitHub emits for footnotes
  and heading anchors) **is allowed**, and scrolls the body in place. ADR-090 would have sent it to the
  browser as `github.com/#user-content-…`, which is the wrong page. This is the one change to
  ADR-090's policy.
- **Every other link opens in the browser**, as ADR-090 intended.
- **Anything else is refused**: form posts, reloads, and scripted or meta-refresh navigations.

## Consequences
- A clicked link in a PR body now opens in the browser instead of replacing the body. That is the
  first time ADR-090's security posture ("comment bodies are written by strangers") has actually
  held for navigation. The CSP was always in force, so nothing could run or phone home.
- Relative links in Enterprise-hosted bodies still resolve against `github.com`. That was true before
  and is unchanged.
- Verified in a smoke instance: PR #288's body and its `github-actions` comment still render, and the
  Tasks thread renders under the same policy. A synthetic click on a link was not run.
