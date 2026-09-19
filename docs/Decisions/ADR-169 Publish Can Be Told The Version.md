---
status: accepted (built 2026-09-19)
date: 2026-09-19
amends: "[[ADR-153 Versions Are Semver And A Release Updates The Tap]] (its consequence that a bump is a hand edit committed before `make publish`; publish can now make that edit and commit itself)"
tags: [adr, release, process]
---
# ADR-169: Publish can be told the version

## Context
User (2026-09-19), while 0.2.0 was being prepared by hand: *"it would be nice if we had a script or make
command to update and publish to a specific version, automatically making the edits and committing them b4
cutting the release"*.

[[ADR-153 Versions Are Semver And A Release Updates The Tap]] put the version in one file and made a release
one guided command, but left the bump outside it: "one edit to `Version.xcconfig`, committed before
`make publish`". Preflight then refuses a version that is already tagged with "bump MARKETING_VERSION", which
sends the user off to make an edit and a commit the script is perfectly able to make. The same session found
a second copy of the version, the hook helper's MCP `serverInfo`, still saying `0.1.0`; it now reads the app's
plist, so the file really is the only edit a bump needs.

## Options
1. **A separate `make bump VERSION=…`**, then `make publish`. Two commands, and a bump committed on a machine
   that then fails preflight.
2. **`make publish VERSION=…` bumps first, then runs preflight.** One command, same stray commit on failure.
3. **`make publish VERSION=…` bumps as the last act of preflight.** Nothing is written until the branch,
   credentials, tag, ordering and clean tree have all passed.
4. **Keywords** (`VERSION=minor`). Cheap, but the user asked for a specific version, and a typed number is the
   thing that ends up in the tag; saying it once, literally, is the safer habit.

## Decision
Option 3. `scripts/publish` takes an optional positional `VERSION`, and `make publish VERSION=0.3.0` passes it
(`ARGS="--dry-run"` passes flags). With no version it releases what `Version.xcconfig` holds, as before.

- The named version is validated as semver before anything else. A leading `v` is refused with the bare
  number suggested (ADR-153: tags carry no `v`).
- Preflight checks the **target** version: not tagged, not released, and, new here, **after the last tag in
  semver order** (`0.2.0-beta.1 < 0.2.0-rc.1 < 0.2.0 < 0.2.1`, numeric identifiers compared as numbers). The
  comparison is with the last tag rather than the file, so `0.2.0-beta.1` can be cut while the file already
  says an unreleased `0.2.0`. The origin fetch moved ahead of the tag checks so they see origin's tags.
- When the target differs from the file, the **last step of preflight** rewrites the one `MARKETING_VERSION`
  line, re-reads it to confirm, and commits only that file as **`Bump the version to <version> (ADR-169)`**.
  The commit counts towards the unpushed commits that the publish step pushes with the tag, so it reaches
  origin only when the release does. If the build or smoke test fails afterwards the bump stays as a local
  commit and a re-run, with or without the version named, carries on from it.
- The generated notes leave that subject out: the script's own bump is not news.
- `--dry-run` says what it would write and commit, and writes nothing.

## Consequences
- A release is `make publish VERSION=<version>` from a clean `main`. The hand edit still works and is what
  preparing 0.2.0 used.
- An aborted release can leave one unpushed bump commit on `main`. It is correct for the next attempt; to
  abandon the version entirely, `git reset --hard HEAD~1` before anything else is committed.
- README's releasing line and the design tree name the new form.

## Verification
- Loaded as a module: eleven versions from `0.1.0` through prereleases to `1.0.0` sort into semver order from
  either direction; `v0.3.0`, `0.3`, `1.02.0` and `latest` are refused, the first with "try 0.3.0".
- `make publish VERSION=… ARGS="--dry-run --yes"` in the repo: `0.1.0` stops at "tag 0.1.0 already exists",
  `v0.3.0` is refused before preflight, and the rest reach the clean-tree check (the tree held this change).
- In a throwaway clone with the change committed, `step_preflight` called directly so no build started:
  `0.0.9` refused as not after `0.1.0`; a dry run for `0.3.0` left the file at `0.2.0`; the real run wrote
  `0.3.0`, committed one file with the expected subject, left the tree clean and reported one more unpushed
  commit; a second run found nothing to bump. The notes built there listed every commit since `0.1.0` and not
  the bump.
- **Not run**: a whole release through the new argument. 0.2.0 was bumped by hand before this existed, so the
  first real use is the release after it.
