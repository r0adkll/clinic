---
status: accepted (phase 1 building 2026-10-14)
date: 2026-10-14
amends: "[[ADR-097 Notification Sounds]] (a pack line, when there is one, is the notification's sound), [[ADR-111 Nav Rows Wear Accent Tiles]] (a fifth nav row)"
tags: [adr, sounds, notifications, sidebar, openpeon, cesp]
---
# ADR-199: Clinic plays OpenPeon sound packs

## Context
User (2026-10-14): *"Let's build a direct integration with this, https://openpeon.com/, into Clinic. I'm thinking
a top tab in the sidebar."*

OpenPeon is an open standard, **CESP v1.0** (Coding Event Sound Pack Specification), for sound packs that play
on coding-agent events, plus a registry of them (371 packs on 2026-10-14, mostly game voice lines: Warcraft's
Peon, GLaDOS, StarCraft…). Its reference player, peon-ping, is a set of shell hooks installed into
`~/.claude/settings.json`.

What the standard fixes, read from `spec/cesp-v1.md` and openpeon.com/integrate:
- **Nine categories** in two tiers. Core, which a player MUST support: `session.start`, `task.acknowledge`,
  `task.complete`, `task.error`, `input.required`, `resource.limit`. Extended: `user.spam`, `session.end`,
  `task.progress`. A player MUST NOT invent others.
- **A pack** is a folder holding `openpeon.json` (`cesp_version`, `name`, `display_name`, `version`,
  `categories` → `{ sounds: [{ file, label, sha256?, icon? }] }`, optional `category_aliases`, `icon`) and a
  `sounds/` folder. Files are WAV, MP3 or OGG, at most 1 MB each and 50 MB per pack, with names matching
  `[a-zA-Z0-9._-]+`, paths relative and never above the pack root, and contents checked by magic bytes. A file
  with no slash gets a `sounds/` prefix.
- **A player** MUST pick a random line, SHOULD avoid repeating the last, MUST offer a 0–1 master volume and a
  per-category off switch, SHOULD offer a mute, MUST skip silently a category the pack lacks, and skips a line
  within 500 ms of the last in the same category.
- **The registry** is `https://peonping.github.io/registry/index.json`. Each entry names a GitHub
  `source_repo`, a `source_ref` tag and a `source_path` folder inside it, plus `manifest_sha256`,
  `trust_tier` (official / verified / community), `quality` (gold / silver / flagged), tags, language, license
  and `preview_sounds`. Installing means fetching `github.com/{repo}/archive/refs/tags/{ref}.tar.gz` and
  extracting that folder.

Measured before deciding:
- **OGG plays.** About 7 % of the registry's preview files are `.ogg`. `AVAudioPlayer` and `AVAudioFile`
  decoded a registry Vorbis file on this Mac (macOS 26), so no decoder package is needed. A line that fails to
  play anyway is treated as a missing line.
- **The registry is loose.** `preview_sounds` is sometimes a list of strings and sometimes a list of objects,
  `source_path` is empty for some packs at a repository's root, `total_size_bytes`, `quality` and `tags` are
  missing on some entries, and some labels are explicit. It is decoded tolerantly: 370 of 371 entries load,
  with only the flagged one dropped. An entry is never installed without the user asking.
- **peon-ping can be silenced in one process tree.** `peon.sh` takes its data directory from
  `CLAUDE_PEON_DIR` when that folder has a `packs/` subfolder, and plays nothing while `.paused` exists there.
  A Clinic-owned folder with both, put in a session's environment, silences peon-ping in that session alone
  without touching the user's install. (Read from `peon.sh`, not run: peon-ping is not installed here.)

## Decision
A round of seven questions (2026-10-14). The user took every recommendation.

1. **A fifth nav row, Sounds** (`speaker.wave.2`, ⌘⌥S), under Automations, with the ADR-111 tile. Choosing a
   pack is browsing 371 of them, playing their lines and assigning them to projects and sessions, so it is a
   destination and not a preference. The screen has three sections: **Browse** (the registry, searchable,
   filtered by tag, with a ▶ on every line), **Installed** (with updates, and packs found on this Mac), and
   **Events** (what Clinic voices). The master switch, volume and default pack sit in the screen's footer.
2. **A pack line replaces the notification sound** (amends ADR-097). When a moment that notifies also has a
   pack line, Clinic plays the line and posts the card or system notification silent, the way ADR-097 already
   does for a user's file. When the pack has no line for that category, or the category or witness is off,
   ADR-097's rotation (or Ping, or the system sound) plays exactly as before. One moment makes one noise.
3. **A session's pack** is, first to last: the session's own override, its project's pack, a pick from a
   rotation that the session keeps for its life (resume included), then the default pack. A child session
   (ADR-181) takes its parent's pack. Each project can have a voice, the way it has an icon.
4. **Packs install into Clinic's Application Support** (`…/Clinic/SoundPacks/{name}`, so Clinic Dev keeps its
   own, ADR-176). `~/.openpeon/packs` and peon-ping's `~/.claude/hooks/peon-ping/packs` are listed as *Found on
   this Mac*: they can be played and chosen, but are never written (ADR-018).
5. **Clinic voices its own witnesses too**, each mapped to an existing category and switched on or off in the
   Events table. Hook witnesses: session started (`startup`/`resume`, not `clear`/`compact`), prompt
   submitted, rapid prompts (three in ten seconds), turn finished, turn failed, permission needed, input
   needed, session ended. Clinic-only witnesses: a run finishing or failing, a watched pull request's checks
   passing or failing, a child's report arriving, an agent asking through `notify_user` or a Grill round,
   context passing 90 %, the plan's five-hour window nearly spent, and a turn running past ten minutes
   (`task.progress`, off by default).
6. **Lines play for every tab**, including the one on screen. One setting, *Stay quiet for the tab I'm
   looking at*, turns that off. Only one line plays at a time. A line that arrives while another plays is
   dropped unless it outranks it (`input.required` > `task.error` > `resource.limit` > `task.complete` >
   everything else), in which case it cuts in. A muted session (ADR-066) is never voiced. `session.start` has
   a 30-second cooldown across sessions, so restoring tabs at launch is not a chorus.
7. **peon-ping alongside Clinic.** When its hooks are in `~/.claude/settings.json`, every event in a Clinic
   session plays twice. The Sounds screen says so, and offers to import peon-ping's `default_pack`, volume,
   categories and `path_rules` (matched to projects). Clinic may also put `CLAUDE_PEON_DIR` pointing at its
   own paused folder into the sessions it launches, so peon-ping stays quiet there and keeps working
   everywhere else. That is offered as a choice, never done silently.

### Safety
An install fetches `openpeon.json` and then each file it names, one by one, from
`raw.githubusercontent.com/{repo}/{ref}/{path}/…`. It does not use the tag's tarball, as the integrate guide
suggests: the 48 official packs share one repository, whose tarball is 62 MB for a pack of under 1 MB
(measured with Peon, 888 KB installed). Fetching file by file also means nothing the manifest does not name (a
script, a symlink, another pack) can ever reach the disk.

The pack is assembled in a staging folder and swapped in only once it has passed every check:
- the manifest's SHA-256 matches `manifest_sha256`;
- the manifest is CESP 1.x with a valid `name`;
- every file has a safe relative path, is at most 1 MB, and starts with its format's magic bytes (an MP3 may
  also start with any MPEG frame sync, not only the spec's `FF FB`);
- every `sha256` any line gives for a file matches.

A file that fails is left out and counted. A checksum that disagrees refuses the whole pack. Nothing in a
pack is ever executed. `quality: flagged` entries are hidden, and every entry shows its trust tier and license.

### Phases
1. Browse, preview, install, update and uninstall. A default pack. The hook witnesses, plus the ones that
   already notify (runs, checks, child reports, `notify_user`, Grill rounds). Volume, mute, per-category and
   per-witness switches, and the quiet-for-the-tab-on-screen setting. Pack lines replacing the notification
   sound.
2. Per-project and per-session packs, the rotation, children inheriting, and the line's label and pack icon
   shown on the attention card.
3. The witnesses Clinic must newly detect (context, plan window, long turns), and peon-ping detection,
   import and silencing.

## Consequences
- ClinicCore gains `CESP` (categories, manifest, alias and path resolution), `SoundRegistry` (the index),
  `SoundPackInstaller` (fetching, checking and installing) and `SoundRouter` (witness → category, debounce,
  no-repeat, spam, cooldown and priority), all Foundation and CryptoKit and unit-tested without a speaker.
- The app gains `SoundPackStore` (registry, installed packs, install jobs, previews), `SoundPackPlayer` (the
  routed `AVAudioPlayer`, at the user's volume) and `SoundsScreen`. `TabStore.notify` takes the witness that
  caused it, and stays the one router for attention.
- Like ADR-097's files, pack lines are played by Clinic and so are not silenced by Focus. Honouring Focus would
  need the Focus Status entitlement, which is left for later.
- The nav block grows by one 33 pt row, taken from the project list.

## Verification (phase 1, 2026-10-14)
- `make test`: 669 pass, 15 of them new (manifest, registry, versions, magic bytes, installer, router,
  settings). The first full run caught a real bug. One file named by two categories, only one of which gave a
  `sha256`, had its checksum skipped whenever the dictionary happened to yield the other category first. Every
  checksum a file is given is now checked, and the sound tests pass five runs in a row.
- Live registry, from a throwaway test: 370 entries decode. Peon, GLaDOS, ITYSL (an empty `source_path`) and
  The Abbot installed over HTTP in 0.6–0.8 s each, with no line skipped.
- Clinic Dev, end to end, with no model: Peon seeded into its own `SoundPacks`, one session in a scratch
  folder, and synthetic hooks through `clinic-hook`. The `sounds` log shows:
  - `session.start` "What you want?", with the second start 3 s later held by the cooldown;
  - `task.acknowledge` "OK." then "Okie dokie." (no repeat);
  - the third prompt in ten seconds as `user.spam` "No time for play.";
  - `input.required` for the permission request, and `task.complete` for the Stop, each with its
    notification recorded (`attention for …`) and posted through the voiced, silent path;
  - nothing for `SessionEnd`, since Peon has no `session.end` lines.
- **Not looked at:** the Sounds screen and its nav row. Screen capture is declined on this Mac, and this
  session is not trusted for accessibility (`AXIsProcessTrusted() == false`). To check by hand in Clinic Dev:
  1. Open Sounds (⌘⌥S, or the row under Automations).
  2. Browse lists about 370 packs, and the tag chips filter them.
  3. Select a pack: the line capsules play and stop.
  4. Install it: it becomes the default and shows under Installed.
  5. Events switches each witness and category.
  6. The footer's volume slider plays a sample when released.
