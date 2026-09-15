---
status: accepted (built 2026-09-14)
date: 2026-09-14
amends: "[[ADR-010 Distribution]] (the release automation it deferred to the first tag) and [[ADR-024 Milestones and Versioning]] (what a version number is and where it lives)"
tags: [adr, release, process]
---
# ADR-153: Versions are semver, and a release updates the tap

## Context
User (2026-09-14): *"We should go ahead and move our versioning and versioning schema to semver, starting
with 0.1.0. Then we need to make it a part of the release process to update the tap repo with our
Clinic's cask."*

[[ADR-010 Distribution]] settled Developer ID, notarization, a direct download and a Homebrew cask, and
deferred the automation to the first tag. [[ADR-024 Milestones and Versioning]] said "0.x semantic
versioning" but nothing about where the number lives or what the build number is. Taking stock before
the first release found:

- `MARKETING_VERSION` was a string in `project.yml`, `CURRENT_PROJECT_VERSION` a constant `1`, and
  `Info.plist` said `CFBundleShortVersionString` `1.0` and `CFBundleVersion` `1`. Every build Clinic has
  ever made reported itself as 1.0, so the daily update check ([[ADR-066 Attention]], `UpdateCheck`)
  would have judged a `0.1.0` release *older* than the running app and never announced it. The cause is
  XcodeGen: the target's `info:` block **writes** `Info.plist` on every `xcodegen generate`, and with no
  version keys given it writes its defaults — so editing the plist by hand lasts until the next
  `make project`, which is exactly what happened on the first attempt at this fix.
- `scripts/release.sh` builds, notarizes and staples a `Clinic-<version>.zip`, and stops there. No tag,
  no GitHub Release (which `UpdateCheck` polls at `releases/latest`), no cask.
- The tap `r0adkll/homebrew-tap` holds formulae that cargo-dist pushes from hardcover-cli and
  perfetto-cli on each of their releases, committed as `<name> <version>`. It has no `Casks/`.

## Options
1. **Keep the version in `project.yml`**, add a publish script that greps it. Works, but the plist bug
   shows how easily a second copy drifts, and XcodeGen settings are not what `xcodebuild` on the command
   line reads first.
2. **A `VERSION` file** the scripts read and pass as `MARKETING_VERSION=…` to every build. Xcode's own
   builds would then not know the version unless the Makefile is the only way to build.
3. **A checked-in `Version.xcconfig`** that the project's configurations are based on, which includes the
   gitignored `Local.xcconfig` for the team id. One file, read by Xcode, `xcodebuild` and `sed` alike.
4. **Publish from CI on a tag**, as hardcover-cli does. Needs the Developer ID certificate exported as a
   secret and the GhosttyKit build on a runner for every release.
5. **Publish locally** after `make release`, with the notarized app smoke-tested in between.

## Decision

### The version is semver and lives in `Version.xcconfig`
`MARKETING_VERSION` is `MAJOR.MINOR.PATCH[-prerelease]`, starting at **0.1.0**, and is set in one place:
`Version.xcconfig`, which both configurations use as their base and which `#include?`s `Local.xcconfig`.
The `info:` block in `project.yml` sets `CFBundleShortVersionString: $(MARKETING_VERSION)` and
`CFBundleVersion: $(CURRENT_PROJECT_VERSION)`, so the plist XcodeGen writes carries the build settings
rather than numbers of its own. `scripts/version.sh` reads and validates the version for every script and refuses anything that
is not semver.

0.x means what semver says: the API is the app, and until 1.0 a minor bump may change behaviour. ADR-024's
"0.1.0 when milestone 1 is usable daily" is long past — six milestones are in — and 0.1.0 is kept anyway,
because it is the first build anyone else can install and the number should say so.

### The build number is the commit count
`CURRENT_PROJECT_VERSION` is `1` in `Version.xcconfig` for development builds and
`git rev-list --count HEAD` for a release, passed on the `xcodebuild archive` command line. It is
monotonic on `main`, never needs a hand bump, and gives Sparkle — when it comes — a `CFBundleVersion`
that orders builds of the same version.

### A release is one guided `make publish`
`make publish` runs `scripts/publish`, a Python script in the shape of Campfire's `scripts/release`
(user, 2026-09-14: *"could we make 'make publish' be interactive like we do for the release script in
Campfire. It can walk through the make release, run the app for me to smoke test, then either detect its
close or let me prompt it to continue"*). Numbered steps, each stopping at a blocker with the command that
clears it; long commands run quietly under a spinner with their output in `build/publish/*.log`;
`--yes` takes every default without asking and `--dry-run` changes nothing.

1. **Preflight** — on `main`, `gh` authenticated, `Local.xcconfig` present, a Developer ID Application
   identity in the keychain, the `clinic-notary` profile answers `notarytool history`, the version is
   semver and neither tagged nor released, `origin/main` fetched (behind → offer a fast-forward; ahead →
   those commits go out with the release), working tree clean so the tag points at what was built.
2. **Build** — runs `scripts/release.sh` (still usable alone as `make release`): archive, Developer ID
   export, notarize, staple, zip, refusing a bundle whose reported version disagrees with
   `Version.xcconfig` or that carries any `shell-integration` file ([[ADR-034 Ghostty Config Overrides
   and Shell Integration]]). A zip already built for this version can be reused (`--reuse-build`
   preselects it) once it is checked to hold a stapled app of this version. Then `spctl` must accept it.
3. **Smoke test** — launches the notarized app with `open -n -W` and waits for it to quit, *or* for
   Enter, to go on with it still running; then asks whether it passed. A running Clinic is detected by
   `ps` (`pgrep -f` cannot read another process's arguments from a sandboxed shell) and the default then
   becomes a smoke instance with its own `CLINIC_APP_SUPPORT` under `build/publish/`, because a second
   instance on the default directory takes over the live app's sockets; preferences are still shared.
   `--skip-smoke` and `--yes` skip it.
4. **Notes** — `build/publish/notes-<version>.md`: the first-parent commit subjects since the previous
   tag with a compare link, or "the first public build" when there is none, plus an Install section
   with the cask command; shown, and editable in `$EDITOR`. Kept across re-runs; `--notes FILE` replaces it.
5. **Publish** — one confirmation, then: push `main` if ahead; tag **`<version>`** — the bare semver, no
   `v` prefix (user, 2026-09-14: *"we shouldn't version the releases/tags with 'v'"*) — derived from the
   file so the two cannot disagree; `gh release create` with the zip and the notes; clone or refresh
   `r0adkll/homebrew-tap` under `build/publish/`, rewrite **`Casks/clinic.rb`** with the version and the
   zip's sha256, commit as `clinic <version>` (the tap's existing convention) and push. Optionally
   `brew update && brew fetch --cask` to prove the URL and sha resolve.

The cask text is a template in `scripts/publish`, so the clinic repo owns it and the tap only ever
receives it. It declares `arch: :arm64` and `macos: :sequoia` (a minimum, in Homebrew 7's DSL) because the
build is Apple Silicon only ([[ADR-010 Distribution]]) and the deployment target is 15; a `livecheck`
against the GitHub releases; `uninstall` that stops the wake agent ([[ADR-095 Automations]]) and quits
the app; and a `zap` that trashes Application Support and the preferences domain.

### A prerelease is a GitHub pre-release and leaves the cask alone
A version with a `-suffix` is published `--prerelease`. GitHub's `releases/latest` — the only thing
`UpdateCheck` reads — skips pre-releases, and so does the tap: a `brew install --cask r0adkll/tap/clinic`
always gets the last stable version. The converse rule matters too: a stable release must **not** be
flagged pre-release on GitHub, or the app never hears of it.

### Local, not CI, for now
Option 5, reaffirmed after weighing CI (user, 2026-09-14: *"Lets stick with the local release flow for now"*).
CI would need the Developer ID certificate and notary credentials as repository secrets, manual signing,
and a tap token; the pieces are known and none is blocking, but the smoke-test between the two steps is
worth keeping while releases are rare. The certificate stays in the login keychain and the smoke-test between the two steps is the
point. Moving publish to a tag-triggered workflow is a later ADR, once the cert and notary credentials are
worth keeping as repository secrets.

## Consequences
- Users install with `brew install --cask r0adkll/tap/clinic` and update with `brew upgrade`. The daily
  update check links to the release page as before; Sparkle remains milestone 2+ per ADR-010.
- `README.md` gains an install section and stops saying "Pre-0.1".
- Bumping a version is one edit to `Version.xcconfig`, committed before `make publish`.
- The tap's README still documents only danger-kotlin; the cask is discoverable by `brew search` once
  the tap is installed, and the README can name it when it exists.
- `Local.xcconfig.example` says the version lives elsewhere, so nobody adds one there.

## Verification
- `xcodegen generate` succeeds with `Version.xcconfig` as the base; `-showBuildSettings` reports
  `MARKETING_VERSION = 0.1.0`, `CURRENT_PROJECT_VERSION = 1`, `DEVELOPMENT_TEAM` from the included
  `Local.xcconfig`, and `CURRENT_PROJECT_VERSION=121` when passed on the command line.
- A Debug build's `Info.plist` reads `0.1.0` / `1` (it read `1.0` / `1` before, and again after the
  first, hand-edited attempt was regenerated away).
- `release.sh` and `version.sh` pass `bash -n`; `version.sh` yields `0.1.0`, tag `0.1.0`, build `121`, no
  prerelease. `scripts/publish --dry-run` walks preflight on this machine — certificate, notary profile,
  tag and release absent, origin fetched — and stops, correctly, at the dirty working tree of the session
  that wrote it. Loaded as a module: the cask it renders lints clean, the notes read as intended for a
  first and a later release, `0.2.0-beta.1` is a prerelease and `0.1.0` is not, the wait loop returns
  when its child exits, and the running Debug Clinic is found by `ps` after `pgrep -f` returned nothing.
- The cask the script emits, rendered with a placeholder sha, passes `ruby -c` and `brew style` with no
  offences (after three the cop asked for: no platform in `desc`, the bare `macos:` symbol, `launchctl`
  before `quit`).
- **Not run**: the build, smoke-test and publish steps end to end — they submit to Apple, launch the app,
  and push a tag, a Release and a tap commit. They run when 0.1.0 is actually cut; `open -n -W --env`
  waiting for the smoke instance is taken from the documented behaviour and the earlier smoke-instance
  notes rather than exercised here.
