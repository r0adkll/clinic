---
status: accepted (consent model superseded by ADR-070)
date: 2026-09-07
tags: [adr, ui, claude]
---
# ADR-051: Claude usage panel

## Context
Collins shows plan usage (5-hour session, weekly all models, weekly model-scoped, extra usage credits) from `GET https://api.anthropic.com/api/oauth/usage` with the CLI's OAuth token and header `anthropic-beta: oauth-2025-04-20`, polled every 5 minutes. The endpoint is undocumented. On macOS the CLI stores the token in the Keychain (service `Claude Code-credentials`), not in `~/.claude/.credentials.json`.

## Decision
- Collapsible "Claude usage" panel at the bottom of the sidebar: one bar per `limits[]` entry (`kind`, `percent`, `severity`, `resets_at`, optional `scope.model.display_name`), plus credits from `extra_usage` or `spend` when enabled.
- Token read from the Keychain (`SecItemCopyMatching`, generic password, service `Claude Code-credentials`), falling back to the credentials file. Read-only; never refreshed by Clinic. Expired token → "Sign in with `claude` to refresh".
- Poll every 5 min while the app is active and the panel is expanded; on demand via a refresh button. Parsing tolerates missing and unknown fields; an HTTP error shows as one caption line.
- Can be hidden in Preferences.

## Consequences
- First Keychain read triggers a macOS prompt for Clinic; "Always Allow" is the expected answer.
- Breakage of the undocumented endpoint degrades to a caption, never a crash.
