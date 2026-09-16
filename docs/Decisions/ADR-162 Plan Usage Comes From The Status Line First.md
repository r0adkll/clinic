---
status: accepted (built 2026-09-16)
date: 2026-09-16
supersedes: "[[ADR-051 Usage Panel]]'s Keychain read (`SecItemCopyMatching`) and its 5-minute poll; [[ADR-070 Usage Panel Consent]]'s rule that the panel shows nothing before connecting"
amends: "[[ADR-157 The Status Line Reports Context]] (`rate_limits` is now read)"
tags: [adr, ui, claude, sidebar, hooks]
---
# ADR-162: Plan usage comes from the status line first

## Context
User (2026-09-16): *"The usage panel is repeatedly asking me for my login to update. Is there anyway we can reduce /
avoid this?"*

[[ADR-051 Usage Panel]] read the token `Claude Code-credentials` with `SecItemCopyMatching` on every poll, every 5
minutes. macOS only skips the prompt while the "Always Allow" it granted Clinic still matches the calling app, and
Clinic kept losing that match: rebuilds, builds at other paths, and the CLI rewriting the item on each token refresh
(the item's modification date was today). The CLI (2.1.273) reads and writes the item with `security` itself
(`security -i` + `add-generic-password -U`), so the item trusts `/usr/bin/security`. Checked on this Mac:
`/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` returned the credentials at once, with no
dialog.

Orca (stablyai/orca) solves the same problem. Its status line script forwards `rate_limits` to the app ("costs no
usage-endpoint budget (the endpoint 429s under Orca's polling)"). It polls `/api/oauth/usage` only when that live
data is stale, and it reads the token by running `security find-generic-password … -w`.

The status line input documents `rate_limits { five_hour, seven_day, spend_limit }`, each `{ used_percentage 0–100,
resets_at epoch seconds }`. A window is present only while its reset is ahead. The CLI builds this from the
`anthropic-ratelimit-unified-*` headers of its own responses. It passes on only `five_hour`, `seven_day`, and
`spend_limit` behind a gateway, so **the per-model weekly limit ("Fable") and extra usage are not there**. The CLI's
only other source of `model_scoped` is its SDK `/usage` data, which calls the same endpoint.

## Options
- **Status line only.** No credential at all, but the Fable bar and the credits line disappear. Rejected.
- **Keep the Keychain API and poll less.** Fewer prompts, never none. Rejected.
- **Status line for 5h/7d, the endpoint for the rest, the token read through `security`.** Chosen.

## Decision
- **`StatusLineReport` decodes `rate_limits.five_hour` and `seven_day`** into `RateWindow { usedPercentage,
  resetsAt }`. It accepts a millisecond `resets_at` too, as Orca does.
- **Every status line event reaches `UsageService.absorb`**, whether or not the session has a tab. The windows belong
  to the account, so one value serves every session. `LiveRateLimits` keeps the newest reading of each window. A
  window a report leaves out is no news, not cleared. A repeated window keeps its first arrival time.
- **`UsageSnapshot.combining(fetched, live:)`** (ClinicCore, pure, tested) lays the live windows over the fetch:
  - A reading replaces the `session` / `weekly_all` bar when it arrived after the fetch and has not reset.
  - The model-scoped bars, credits and plan name stay as fetched.
  - A live bar's severity is `exceeded` at ≥ 100 and `normal` otherwise; the tint still turns orange at 90 %.
  - "Updated …" shows the later of the fetch and the newest reading.
- **The live windows need no connection.** Not connected, the panel shows them with a shorter line: *Connect to add
  per-model limits and extra usage*. The Preferences toggle "Show usage in the sidebar" is no longer disabled while
  disconnected. Disconnect forgets the fetch and the token and keeps the live windows.
- **The endpoint poll stays behind consent** ([[ADR-070 Usage Panel Consent]]) and now runs **every 15 minutes**. The
  live windows cover what changes fastest.
- **The token is read by running `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`**, off the
  main actor, falling back to `.credentials.json`. It is held in memory until `expiresAt`. An expired token or a 401
  re-reads it once and retries, because the CLI refreshes the item only when it next uses it. Clinic still never
  refreshes or stores it (ADR-018).

## Consequences
- The Keychain prompt should not appear again, from any build or path. Checked with `security` from a shell, not
  yet from the built app.
- With a session running, 5h/7d move with every turn instead of every poll.
- Sessions not launched by Clinic (and `claude attach`, which takes no `--settings`) report nothing. Without a Clinic
  session, the panel is as fresh as the last poll.
- Clinic assumes one Claude account. A session using a different `CLAUDE_CONFIG_DIR` would lay its account's windows
  over the default account's fetch. Orca filters by config dir; Clinic can add that if it ever supports several
  accounts.
- Any process running as the user can read the token through `security`. That was already true, and it is how the
  CLI reads it.
- Not verified in the app UI with a live session: the decoding, merging and fallback are covered by unit tests, and
  the app builds.
