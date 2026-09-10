---
status: accepted
date: 2026-09-07
tags: [adr, ui, ops]
---
# ADR-038: Preferences and Diagnostics

## Decision
No preferences window in milestone 1. The hook trace toggle is a hidden `defaults write com.r0adkll.clinic` key. Logging via `os.Logger`, subsystem `com.r0adkll.clinic`, one category per store. 'Reveal Logs' is milestone 2.


## Amendment (2026-09-09): what `CLINIC_APP_SUPPORT` does *not* isolate

A smoke instance gets its own state, sockets, chats and snapshots, because all of those hang off
`CLINIC_APP_SUPPORT`. **`UserDefaults` is not among them** — it is keyed by bundle id, which both
instances share — so every preference is common to the smoke run and the app the user is really using:
shortcut overrides, panel visibility, quit behaviour, the marketplace query, the usage consent, and the
automations wake agent ([[ADR-095 Automations]]).

This surfaced as a macOS password prompt over the window under test. [[ADR-070 Usage Panel Consent]]
made the usage panel poll silently on later launches once consent is stored; a smoke instance inherits
that stored consent, polls the Keychain on launch, and macOS prompts because the smoke build sits at a
different path than the keychain item's ACL trusts.

`ClinicPaths.isSmokeInstance` now names the condition, and the rule is: **anything that acts outside
Clinic's own container on the strength of a stored preference must check it first.** Two callers do
today — the usage panel does not auto-poll (connecting by hand still works if a run needs it), and the
wake agent refuses to register, since it would install a real LaunchAgent pointing at the installed app
that outlives the test.

A full fix is a separate `UserDefaults` suite for smoke instances, which would touch every `@AppStorage`
in the app and needs its own ADR. Until then the sharing is a known hazard rather than a surprise.

Unrelated but worth recording, since it looks identical: a **debug build** prompts for
`Claude Code-credentials` on its own usage poll, because each build is a new binary at a DerivedData
path the keychain ACL has not seen. That is the dev loop, not the smoke harness.
