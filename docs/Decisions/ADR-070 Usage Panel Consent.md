---
status: accepted
date: 2026-09-07
supersedes: part of ADR-051
tags: [adr, ui, claude, privacy]
---
# ADR-070: The usage panel reads the Keychain only after the user connects

## Context
[[ADR-051 Usage Panel]] polled on launch, which triggered a macOS Keychain prompt for "Claude Code-credentials" before the user had asked for anything. User (2026-09-07): do not prompt for credentials by default; show the panel in a state where the user can connect, with a matching setting.

## Decision
- The panel starts **disconnected**: a sentence explaining what connecting does and a **Connect Claude account** button. Nothing reads the Keychain until it is clicked; the macOS prompt appears then, once.
- Consent is remembered (`ClinicUsageConnected`); on later launches polling starts silently. If the read fails, consent is cleared and the error is shown under the button.
- Preferences → General has the same control: **Connect…** / **Connected · Disconnect**. Disconnect stops polling and clears the snapshot; Clinic never stores the token.

## Consequences
- The launch-time Keychain prompt that made dev builds annoying is gone; the "Show Claude usage" toggle only controls visibility.
