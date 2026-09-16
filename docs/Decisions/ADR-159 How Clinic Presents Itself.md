---
status: accepted (built 2026-09-16)
date: 2026-09-16
amends: "[[ADR-010 Distribution]] (the cask's description), [[ADR-038 Preferences and Diagnostics]] (three more smoke launch arguments)"
tags: [adr, distribution, readme, screenshots]
---
# ADR-159: How Clinic presents itself

## Context
User (2026-09-16), after two rounds of Haiku subagents drafted taglines: *"Grill me about these tag lines and a
potential product site for Clinic."* Four rounds of the `grilling` skill, every recommendation accepted, then
*"Let's do it."*

The repo is public ([[ADR-011 Repo Naming and License]]), with no homepage, no images, no topics, and a README
whose second sentence called Clinic a reimplementation of Collins. [[ADR-001 Audience]] still holds: built for
the author's daily use, structured to be publishable. The subagent rounds had settled on the clinic-as-a-place
theme and one-phrase taglines, not strings of fragments.

## Decision
- **No product site yet.** The README is the product page until 1.0; a site would reuse its tagline and images.
- **Tagline: "All your Claude Code sessions, in good hands."** It names Claude Code, because link previews, the
  GitHub About line and search results show the tagline alone. "Sessions" carries the therapy double meaning.
  The GitHub About line uses it without the period. If a second agent ever ships ([[ADR-004 Agent Scope]]),
  revisit.
- **Subheading: "See what every agent is doing, and know which one needs you, from one native Mac window."**
  Warm line first, functional line under it.
- **The clinic metaphor stops at the name and tagline.** Everything else is plain feature language.
- **README order:** tagline, subheading, hero screenshot (dark/light via `<picture>`), the Homebrew line; five
  "What you get" bullets (every session in one sidebar; know when you're needed; the real `claude` CLI in
  Ghostty; everything a session started, under it; diffs, files and pull requests in a side panel) and an
  "Also:" line for Automations and Tasks; Install, with the notarized zip as the fallback and the 0.x note;
  Building; Documentation; **Credits**, where the Collins lineage now lives; License.
- **Elsewhere:** the cask `desc` stays descriptive per Homebrew style, **"Session manager for Claude Code"**
  (the template is in `scripts/publish`, so the next release carries it). Repo topics: claude-code, macos,
  ghostty, swiftui, ai-agents. No homepage URL until there is a site.
- **Images live in `.github/assets/`**: `hero-dark.png`, `hero-light.png`, `social-preview.png`. Not in `docs/`,
  which is the vault ([[ADR-105 The Vault Lives In The Repo]]).
- **`make screenshots` makes all three** (`scripts/screenshots/`), so a UI change re-shoots in one command:
  - **Staged, never real.** `fixtures.py` builds three invented projects (`storefront`, `pantry`, `ledger`) as
    git repos, transcripts in an isolated `CLAUDE_CONFIG_DIR`, and Clinic state (owned sessions, project order,
    an open Grill round) in an isolated `CLINIC_APP_SUPPORT`. Timestamps are relative to now.
  - **A re-identified copy of the app** (`com.r0adkll.clinic.screenshots`, ad-hoc signed). Its preferences are
    its own domain, so the accent, theme, window and panel sizes cannot reach the live app's (the hazard noted
    under [[ADR-152 Clinic Has Its Own Theme And Accent]]), and no Clinic code needs a guard for it.
  - **The terminal is the real CLI** resuming the staged transcript. `.claude.json` marks onboarding done,
    trusts the projects and pre-approves a placeholder API key; `ANTHROPIC_BASE_URL` points at a closed local
    port, so nothing reaches the network. The fixture has no background shell: a resumed CLI marks one as
    ended and retries the turn, which printed a red "Connection refused" line.
  - **States are sent, not performed.** `hooks.py` writes `UserPromptSubmit`, `PermissionRequest` and two
    `StatusLine` payloads to the staged hook socket. The storefront edits are written six seconds later, so
    the Diff pane's turn snapshot sees them as this turn's changes. The six seconds after that also outlast the
    8 s in-window card the waiting session's notification raises.
  - **The scene:** sidebar in Automatic with a working card (three running subagents, one finished, a 42%
    gauge), a session waiting for permission, a closed session raised by its Grill round, compact rows below;
    the working session's conversation; the Diff pane on its turn.
  - **Framing:** a 1440 × 900 pt window at 2×, key (the app is brought to the front, not launched with `-g`),
    with its shadow, in the icon's coral `#D97757` accent. The build step keeps xcodebuild's status, which
    `make build` hides behind `tail`.
  - **Social preview:** `social-preview.swift` draws 1280 × 640 from the dark hero: the icon, "Clinic" and the
    tagline in the icon's cream and coral on the left, the window's top-left on the right. GitHub has no API
    for it, so uploading is a manual step in the repo's Settings.
- **Smoke launch arguments ([[ADR-038 Preferences and Diagnostics]]):** `-ClinicOpenSessionOnLaunch` takes a
  comma-separated list, opened in order; `-ClinicShowPaneOnLaunch diff|files|terminal`;
  `-ClinicWindowContentSize <w>x<h>`; `-ClinicSkipNotificationPermission YES`, so the copy never lands in
  System Settings ▸ Notifications.

## Consequences
- Staging surfaced a real bug in the Diff pane ([[ADR-080 Diff Panel]]): on a file change it decided whether to
  reload the diff *before* refreshing the turn list, so the first change of a new turn loaded the turn and not
  its diff, and the pane read "This turn changed nothing on disk" until a second change. The decision now
  comes after the refresh.
- Running `make screenshots` takes about a minute, needs Screen Recording permission for the terminal, and
  brings Clinic to the front twice; the Mac should be left alone while it runs.
- The footer still shows the staged path (`~/Library/Caches/clinic-shots/storefront`), and the terminal uses
  the running user's own Ghostty theme, so the terminal's look varies with who runs the script.
- The GitHub About line and topics were set on 2026-09-16. The cask description reaches the tap with the next
  `make publish`, and the social preview is uploaded by hand.

## Addition (2026-09-16)
User: *"Let's dress up the readme with putting the icon at the top, the app name under it, then the tagline. Then
the screenshot. The first three should be horizontally centered."* The README now opens with a centred block: the
app icon (`.github/assets/icon.png`, 128 pt, copied from the asset catalog by `make screenshots` so it follows the
app's), "Clinic" as the heading, then the tagline with the subheading beneath it. The hero, the Homebrew line and
everything after keep their order and stay left-aligned. The order above is unchanged; only the icon is new.
