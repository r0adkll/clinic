---
status: accepted (built 2026-10-15)
date: 2026-10-15
amends: "[[ADR-199 Clinic Plays OpenPeon Sound Packs]] (phase 3: the witnesses it listed for `resource.limit` and `task.progress`, and its seventh question on peon-ping)"
tags: [adr, sounds, usage, status-line, peon-ping]
---
# ADR-203: Limits, long turns and peon-ping

## Context
User (2026-10-15): *"Okay, let's continue."* [[ADR-199 Clinic Plays OpenPeon Sound Packs]] left two things for
phase 3. Both were decided there:
- **The witnesses Clinic must newly detect:** context passing 90 %, the plan's five-hour window nearly spent,
  and a turn running past ten minutes (`task.progress`, off by default).
- **peon-ping alongside Clinic** (its seventh question): detect it, explain the double sound, offer to import
  its settings, and offer to quiet it in Clinic's own sessions.

Until now `resource.limit` and `task.progress` had no witness, and the pack page said *"Clinic doesn't play this
yet"* under them.

## Decision
### Limits and long turns
- **Four witnesses:**
  - `contextFilling` → `resource.limit`;
  - `planNearlySpent` → `resource.limit`;
  - `rateLimited` → `resource.limit`, among the hook witnesses, since it comes from `StopFailure`;
  - `turnLong` → `task.progress`.
- **A limit is a crossing, not a level** (`ResourceWatch`, unit-tested). The status line reports many times a
  turn, so:
  - A session's context sounds once on the way past **90 %**. It is armed again only below **80 %**, after a
    compaction or a `/clear`.
  - The five-hour window sounds once per window, the window named by its reset time.
- **A failed turn is a limit when its words say so.** The message is checked for *rate limit*, *usage limit*,
  `429` or *quota*. Such a turn voices `resource.limit` instead of `task.error`. The notification is the same.
- **A long turn is a prompt still working ten minutes later.** It is watched from `UserPromptSubmit`; a newer
  prompt lapses the old watch, and so does leaving *working*. It sounds once. `-ClinicLongTurnSeconds <n>`
  shortens the wait for testing.
- **`turnLong` is opt-in.** `SoundSettings` keeps `enabledOptIns` beside `disabledWitnesses`, so the settings
  of everyone who already has some keep it off: an empty disabled list would otherwise have switched a new
  witness on. The Events table marks it *off by default*.
- The pack page's *when* lines now name these: "context or the plan window past 90%, a rate limit"; "a turn
  still running after ten minutes, if turned on".
- Only packs with lines for a category speak for it. About 90 of the 370 packs have `task.progress` lines;
  the rest stay silent, by the spec's rule.

### peon-ping
- **Detection reads, never writes** ([[ADR-018 Claude Data Write Policy]]). Clinic looks for any hook command
  in `~/.claude/settings.json` that names `peon-ping` or `peon.sh`. It reads peon-ping's `config.json` from
  its hooks folder, then from `~/.openpeon`, the order `peon.sh` uses. `CLAUDE_CONFIG_DIR` is honoured.
- **A banner on the Sounds screen**, under the header, dismissible. When the hooks are installed it reads
  *"peon-ping is installed too"* and explains that each moment is heard twice in Clinic's sessions, and that
  "peon pause" silences it everywhere. When only a config is found it offers the import.
- **Quiet it in Clinic's sessions** (`SoundSettings.quietPeonPing`), a checkbox. Sessions started from then on
  get `CLAUDE_PEON_DIR` pointing at `…/Clinic/PeonPingQuiet`, a folder Clinic writes once with `packs/`,
  `.paused` and `{"enabled": false, "desktop_notifications": false}`. `peon.sh` takes that folder as its own
  and plays nothing. peon-ping elsewhere is untouched. Shells never get the variable; only session terminals
  do.
- **Import Its Settings…** opens a sheet that shows the plan before anything changes:
  - the default pack (`default_pack`, or the older `active_pack`);
  - the volume, clamped to 0–1;
  - categories it turns off;
  - its rotation, unless the mode is `session_override`, which is a slash command rather than a rotation;
  - its `path_rules`, glob-matched against the projects Clinic knows (first match wins, `~` expanded) and
    applied as project packs;
  - what is left out: packs that are not installed (with *install them from Browse and import again*) and
    rules that match no project.

  A project that already has a pack of its own keeps it. peon-ping's own packs folder is already read as
  *Found on this Mac*, so its packs count as installed.

## Consequences
- `ResourceWatch` and `PeonPing` are Foundation-only and tested: crossings and re-arming, one sound per
  window, limit words, opt-in defaults for old settings, hook detection, the import plan, and the quiet folder.
- The quiet folder works by `peon.sh` reading `CLAUDE_PEON_DIR` and `.paused`, as read from its source. peon-ping
  itself was not run here.
- **The banner's paragraph is bounded** (`lineLimit(3)`). The first build gave it `.fixedSize(vertical:)`, and
  measured for the window's minimum size at almost no width, it made the window's content about 2,400 pt
  tall, pushing the header off the top. It is the same failure as [[ADR-178 The Usage Panel's Invitation Is
  Bounded]].

## Verification
- `make test`: ClinicCore 690 pass, seven of them new.
- Clinic Dev, with synthetic hooks and status-line reports through `clinic-hook statusline`, and an isolated
  Claude config holding a fake peon-ping hook line and `config.json`. With Ana (an Overwatch pack that has
  `task.progress` lines) as the default:
  - `turnLong → task.progress` "Correct choice." six seconds after the prompt;
  - context 85 → 92 → 95: one `contextFilling` at 92;
  - `planNearlySpent` at 93 %;
  - a `StopFailure` reading `429 rate_limit_error` as `rateLimited → resource.limit`.

  An earlier run with Peon as the default played no long-turn line, which is correct: Peon has no
  `task.progress` lines.
- The session's processes carried `CLAUDE_PEON_DIR=…/Clinic Dev/PeonPingQuiet`, and the folder held `.paused`,
  `config.json` and `packs/`.
- The banner, captured: title, explanation, the ticked checkbox and *Import Its Settings…*. Its sheet showed:
  - default GLaDOS, volume 20 %, Something failed off, rotation ITYSL;
  - the scratch project to The Abbot;
  - `zug` left out as not installed, and `*/nowhere/*` matching no project.

  *Import* wrote exactly that to the settings and `state.json`, and the footer said "Imported peon-ping's
  settings."
- Clinic Dev's state, settings, quiet folder and scratch folders were removed afterwards. Its installed packs
  stay.
