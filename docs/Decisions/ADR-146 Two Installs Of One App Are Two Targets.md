---
status: accepted (built 2026-09-13)
date: 2026-09-13
amends: "[[ADR-078 Open In Targets and Quick Action]] (what a target is keyed by, and how many an editor yields)"
tags: [adr, ui, open-in, milestone-4]
---
# ADR-146: Two installs of one app are two targets

## Context
User (2026-09-13): *"it looks like the Android Studio being picked up is the preview version, and not the
main one."*

Both installs answer to the same bundle id:

```
/Applications/Android Studio Preview.app        com.google.android.studio
/Users/r0adkll/Applications/Android Studio.app  com.google.android.studio
```

`OpenInApps.refresh` asked `urlForApplication(withBundleIdentifier:)`, which returns **one** URL. Launch
Services prefers the Preview, so the Preview is what the menu offered and what the quick action opened.
There was no way to reach the other install, and nothing in the UI to suggest another existed.

This is not particular to Android Studio. Xcode and Xcode-beta share `com.apple.dt.Xcode` too; so does any
app installed twice — a Toolbox copy in `~/Applications` beside one in `/Applications`. A registry keyed
by bundle id **cannot represent the situation**, whatever UI is put on top of it. That is worth settling
before the Settings panel and the per-project pick of [[ADR-147 Open In Is Configured And Per-Project]],
both of which would otherwise inherit a list that silently drops half the answer.

## Decision

### An install is the unit, not a bundle id
`refresh` uses `urlsForApplications(withBundleIdentifier:)` — the plural — and makes **one target per
install**. A target's `id` becomes its path on disk, which is the only thing that distinguishes two
copies of one app, and `.app(URL)` already opens the exact bundle it names, so opening needed no change.

### The name is the file name
`CFBundleName` is `"Android Studio"` for **both** installs, so the bundle's own idea of its name would
draw the list twice with one label and leave the reader worse off than before. The `.app` file name is
what tells them apart — *Android Studio* and *Android Studio Preview* — and it is also what Finder shows,
so the menu and the Finder window agree. The curated name from the editor list survives only as a
fallback for a bundle with no file name to read.

Two installs that collide on the file name as well take their directory as a suffix, home abbreviated:
*Android Studio (/Applications)* and *Android Studio (~/Applications)*.

### Sorted by name, not by preference
`urlsForApplications` returns Launch Services' preference order, which is exactly the judgement that got
this wrong and which can change without the user doing anything. Sorting by name keeps the menu still
between launches, and puts *Android Studio* above *Android Studio Preview* by construction.

### A pick made before this survives
`ClinicOpenInDefault` held a bundle id. Targets are now keyed by path, so that stored value matches
nothing and the quick action would quietly fall back to Finder. Each target carries the `bundleId` it was
found under; when the stored default matches no target's id but does match a target's bundle id, it is
rewritten to that install's path. The field exists for that migration and for nothing else.

## Consequences
- The menu grows by one row for each app installed twice. That is the point, and for a single install it
  is unchanged — every curated name in the editor list already equals its `.app` file name.
- Which of two installs sits at the top is now decided by alphabetical order, so *Android Studio* wins
  over *Android Studio Preview* by luck of the name rather than by design. The per-project pick in
  ADR-147 is what actually settles which one a project opens in.
- `OpenInTarget.bundleId` is migration scaffolding. It can go once no one is running a build from before
  today, and it should.
- Icons are cached under the target id, so two installs of one app now cache separately — correct, since
  a Preview's icon differs from the release's.

## Verification
- **The cause**: `urlForApplication` returns `Android Studio Preview.app`; `urlsForApplications` returns
  both installs. `CFBundleName` reads `"Android Studio"` for each, which is why the name comes from the
  file name instead.
- **The menu as it now draws**, resolved against this machine: *Xcode*, *Visual Studio Code*,
  *IntelliJ IDEA*, *Android Studio* (`~/Applications`), *Android Studio Preview* (`/Applications`) — both
  Studios present, release first.
- **The collision fallback**, exercised on a synthetic pair that shares a file name: *Android Studio
  (/Applications)* and *Android Studio (~/Applications)*.
- `make build` clean, 460 ClinicCore tests pass. The app target has no test suite, so the naming and
  ordering rule was checked by running it against the machine's real installs rather than asserted.
- **Not verified**: opening each install from the menu, which needs a Clinic restarted onto this build.
