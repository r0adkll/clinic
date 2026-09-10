---
status: accepted
date: 2026-09-09
amends: ADR-017, ADR-061
tags: [adr, automations, scheduling, sessions, ui, milestone-7]
---
# ADR-095: Automations — scheduled sessions

## Context
Clinic starts sessions when you ask it to. Everything it knows how to do — run a prompt in a project,
watch the state machine, snapshot the diff, notify you when it wants you — happens only because a
person was sitting there to begin it. User (2026-09-09): *"an 'Automations' feature/screen where a
user can schedule a cron job to run a prompt (similar to our new session configurator) in a selected
project (or just chat) and for a schedule … They can name the automation and on the main automations
screen there should be a list/tiles of templates that they can pick from."*

The question is not what the screen looks like — [[ADR-084 Plugin Marketplace]] and
[[ADR-093 MCP Server Configuration]] settled that shape twice — but **what actually runs at 9 a.m.**
Everything below was probed against the real CLI (four throwaway `--bg` sessions, all `claude stop`ped
and `claude rm`'d; the repo's worktree list and branch list verified clean afterwards).

### An automation run is a background agent

Three candidate execution shapes, and only one survives contact:

- **A visible tab.** Fires when nobody is there, steals a window, and stalls on the first permission
  prompt with no one to answer it.
- **Headless `claude -p`.** Throws away everything Clinic has built: no state machine, no sidebar row,
  no transcript, no diff snapshot, and no way to pick the conversation back up.
- **`claude --bg`.** Verified: works with no TTY, returns in about a second, prints
  `backgrounded · e6f9d349 · <name>`, takes `-n <name>`, and is attachable afterwards.

**The decisive finding is that Clinic's hooks fire for a `--bg` run.** A `--settings` file pointing at
`clinic-hook` produced `SessionStart` (`source: startup`) and `Stop` carrying the real `session_id`.
So a scheduled run joins the state machine ([[ADR-026 Session State Machine]]), the sidebar
([[ADR-061 Background Agents]]), attention ([[ADR-066 Attention]]), notifications
([[ADR-033 Notification Delivery]]), the transcript reader and the snapshot store — for free. The
Automations feature is a scheduler, a saved prompt and a launcher; the entire downstream already exists.

### Five constraints the probes imposed

- **`--bg` refuses `--session-id`**, printing
  `warning: --bg manages the session id; ignoring --session-id`. [[ADR-017 Session Identity]]'s
  pre-assignment does not hold here. But the printed short id is the first eight characters of the
  full UUID (`e6f9d349` → `e6f9d349-dc80-4619-9704-9f75cf2ef4a0`), so correlation is *deterministic*:
  parse stdout, match the prefix against the next `SessionStart`. No time-window guessing, and it is
  the same rebind-on-SessionStart machinery [[ADR-063 Session Lifecycle Controls]] already built for
  `--fork-session`.
- **A finished background agent stays resident.** After completing, the probe reported
  `status: idle, state: done` with its pid still alive and attachable. A daily automation would leave
  one live `claude` process per run, forever. Reaping is a requirement, not a nicety.
- **`--bg` accepts `-w <name>`.** The probe created `.claude/worktrees/clinic-auto-probe` on branch
  `worktree-clinic-auto-probe`, **locked**, with the agent's cwd inside it.
- **`claude rm <id>` reaps the worktree as well as the job state.** `claude stop` prints
  `run 'claude rm <id>' to remove worktree and job state`, and `claude rm` removed the directory, the
  branch and the lock in one call. Retention is therefore one CLI command, not a git dance Clinic has
  to invent — and this corrects ADR-061, which described `claude rm` as removing job state and said
  nothing about the worktree it also destroys.
- **`claude logs <id>` is a raw ANSI TUI replay**, not readable text — 4 KB of cursor addressing for a
  five-word answer. "What did the automation say" must come from the transcript whose path
  `SessionStart` hands us, never from the CLI. This is the design we wanted anyway.

### A defect found on the way

`BackgroundAgent.isRunning` (`BackgroundAgents.swift`) treats `completed`/`failed`/`stopped` as the
terminal states, but the CLI reports **`done`** with `status: idle`. A finished background agent
currently reads as running, which would make every automation look permanently in-flight. Fixed as
part of this work, not deferred: the check becomes terminal-state-inclusive of `done`, mirroring how
`needsAttention` already had to learn the undocumented `blocked`. **Fixed 2026-09-09**, together with
the same hole in `BackgroundAgentsService.refresh`'s announce trigger list, which meant ADR-061's
"a detached agent reaching `completed` posts a notification" never fired on a normal finish. The three
state sets now live on `BackgroundAgent` (`terminalStates`, `attentionStates`, `announcedStates`) so
running-ness and notify-ness cannot drift apart, and the regression test is the CLI's verbatim
`done`/`idle` payload rather than a hand-written one. ADR-061 carries the correction.

## Decision

### Execution: `claude --bg`, with hooks, correlated by short id

An automation fires by running

```
claude --bg -n "<Automation> · <date>" --settings <hooks.json> [--model …] [--effort …]
       [--permission-mode …] [-w <slug>-<timestamp>] [--mcp-config …] "<prompt>"
```

with the project (or the Chats directory, [[ADR-068 Chats]]) as `cwd`. Clinic parses the short id from
stdout, marks the run *awaiting id*, and binds it to the next `SessionStart` whose `session_id` carries
that prefix. **This amends [[ADR-017 Session Identity]]**: pre-assignment holds for every launch path
except `--bg`, where the CLI owns the id and Clinic learns it deterministically rather than by polling.

Runs appear in the sidebar as the background-agent rows ADR-061 already draws, under their project,
badged as automation-born and named for the automation and its fire time.

### Scheduling: one brain, two ways of being awake

**Cron is the single representation.** `CronSchedule` in `ClinicCore/Automations` is a five-field
parser with a bounded next-fire walk (366-day search cap), pure Foundation and unit-tested — CLAUDE.md
keeps ClinicCore dependency-free and this is 150 lines, not a package. The presets are a picker over
it, not a parallel model: hourly `0 * * * *`, every six hours `0 */6 * * *`, daily `<m> <h> * * *`,
weekly `<m> <h> * * <dow>`, custom. Times are local; DST is whatever the walk over local wall-clock
minutes produces, which is the behaviour cron itself has.

**The scheduler is in-app** — one timer over the next due automation across all of them, rearmed on
every change. There is exactly one scheduler.

**launchd is a wake-up, not a second scheduler.** Behind a preference (*Run automations when Clinic
isn't open*, off by default), Clinic registers a **static bundled** `SMAppService.agent` —
`Contents/Library/LaunchAgents/com.r0adkll.clinic.wake.plist`, `StartInterval` 300 — whose program is
a new bundled helper `clinic-wake`, shaped exactly like `clinic-hook` (`type: tool`, embedded, signed,
copied to `executables`). The helper runs `open -g -j -b com.r0adkll.clinic`, which launches Clinic
hidden and background; the in-app scheduler then does all the work in its normal catch-up pass. This
is why there is no second scheduling path to keep honest — launchd only puts Clinic into the resident
state [[ADR-069 Keep Running and Quit Behaviour]] already designed for.

A static plist is chosen over a hand-written one in `~/Library/LaunchAgents` with computed
`StartCalendarInterval` entries deliberately: the dynamic version means regenerating and
`launchctl bootstrap`ing a plist on every edit, and a cron like `* * * * *` expands to sixty dicts.
The cost is **granularity: in this mode a 9:00 automation may fire as late as 9:04**, which the screen
states plainly next to the preference. Nothing here is cron-scale enough to care.

**Explicit Quit suppresses the relaunch until next login.** Clinic writes a
`wake-suppressed-until-login` marker into its Application Support directory on a user-initiated quit,
and `clinic-wake` checks it before calling `open`. An app that resurrects itself four minutes after
you quit it is hostile; this is the one line of code that prevents it. *Launch at Login*
(`SMAppService.mainApp`) is offered alongside as the gentler mitigation, and is the option most users
should take instead.

**Missed fires do not stack.** Each automation carries a catch-up policy — **Run once** (default) or
**Skip** — applied on launch and on wake against `lastFiredAt`. A weekend of missed hourly runs is one
run or none, never forty-eight. **Overlap is skipped**: if the previous run of the same automation is
still working, the fire is recorded as skipped with its reason rather than queued.

### Permissions: declared per template, never silently bypassed

The probe made the failure mode concrete — a `--bg` run that hits a prompt sits at `needs_input`
indefinitely, and one that cannot use auto mode falls back to manual and waits. So:

- **Every template declares its own `--permission-mode`.** Report-shaped templates run `plan`
  (read-only, structurally incapable of stalling on a write); code-shaped templates run `acceptEdits`.
- **`bypassPermissions` is never a default and never inherited from a template.** It is a per-automation
  opt-in with a stated warning, chosen deliberately or not at all.
- **A stalled run is not left to rot.** Reaching `needs_input`/`blocked` raises attention and posts a
  notification through the ADR-033 path; a per-automation stall timeout (default 30 minutes) then
  stops the run and records it as stalled. An automation that needs you at 3 a.m. has already failed.

### Isolation: a fresh worktree per run, for the automations that write

**Worktree isolation follows the permission posture.** A `plan`-mode automation reads the project
directory and is given no worktree — there is nothing to isolate. An `acceptEdits` automation gets
`-w <slug>-<timestamp>`, a fresh worktree per run, so a nightly job never collides with what you are
doing in the repo.

Retention is `claude rm`, which the probe proved reaps process, job state, worktree, branch and lock
together:

1. **On completion Clinic inspects the run's worktree.** No commits ahead of base and a clean tree →
   `claude rm <id>` immediately. *A run that changed nothing leaves nothing behind*, which is the
   common case for most nights and is what keeps "fresh worktree per run" from becoming thirty
   directories a month.
2. **Otherwise the run is retained** and counts against a per-automation keep-limit (default 5).
3. **Past the limit the oldest retained run is offered for removal**, never silently removed — its
   worktree holds work by definition. The detail pane lists it with a Remove button showing the exact
   `claude rm <id>` argv, in ADR-084's confirmation style, and says that the worktree and its branch
   go with it. Auto-prune is available as a per-automation setting for people who want it.

### The screen

**A nav row in the pinned block under MCP Servers**, taking ADR-084's row metrics unchanged (18×16
glyph box, 6 pt gaps, 6 pt interior, 4 pt vertical padding, 10 pt outer inset). `WindowState.Screen`
gains `.automations` — the third case, which is exactly the growth ADR-093 restructured that enum to
absorb. Default shortcut **⌘⌥A** (verified free: ⌘⇧A is Archive Session), on the View menu beside
⌘⇧M and ⌘⌥M.

**Glyph: `alarm.fill`** — decided on the render. Twenty candidates were drawn at the row's real
metrics (13 pt in an 18×16 box, 13 pt semibold label, 6 pt gaps, the 6 pt-radius pill) in both states
and both appearances, and then *stacked under `storefront.fill` and `server.rack` as the sidebar
actually draws them* — ADR-093's lesson, applied from the start rather than after a single-column
sheet had already misled the decision.

Four glyphs were excluded before rendering, on vocabulary the app has already spent:
`clock.arrow.circlepath` (it means **recent** in Clinic — the Diff panel's session scope and, more
awkwardly, the Quick-starts pill on the very New Session screen this feature's editor reuses),
`bolt` and its variants (ADR-094's Hooks chip), `arrow.clockwise` (refresh), and `sparkle`/`wrench`
(the Replay pane). A destination must not wear a mark that already means something else two screens
away.

What the adjacency view settled, and a flat sheet could not:

- **The predicted box fault is real.** `calendar.badge.clock` and `calendar.day.timeline.left` make a
  third rounded box under two rounded boxes; the block stops being three destinations and becomes one
  texture. Out, exactly as ADR-093 anticipated.
- **The alarm clock breaks the run.** Its two bell ears give a silhouette neither neighbour has, so it
  reads as a different kind of thing at a glance rather than a third variant of the same box.
- **`metronome` is the `bolt.horizontal` failure again.** At 5× it is unmistakably a metronome and the
  most distinct silhouette of the whole set; at the row's real 13 pt it is an anonymous triangle. The
  clearest evidence here that a glyph must be judged at size.
- **`timer` lands one stroke from the clock vocabulary** already spent on "recent", and means
  *countdown* rather than *schedule*. `repeat` reads as media looping; `wand.and.sparkles` vanishes
  against two heavy neighbours; `gearshape.arrow…rotate.90` mushes; `hourglass` says waiting;
  `clock.badge.checkmark` says done.

**Fill over outline, and the method note that decides it.** This ADR first chose outline `alarm`,
claiming `alarm.fill`'s ears merged into its body and its face became a knockout blob. **That claim
was formed on a vector re-rendered at 5× — the exact error the `metronome` finding had just named.**
Re-run properly (render at the 2× the app actually draws at, then magnify *those pixels* with
interpolation off), it does not hold: at real size the ears stay clearly notched off the body, the
face is a clean knockout with legible hands, and even the feet survive, in light and dark alike.

Three things then favour the fill:

- **It is crisper in the selected state**, which is the state that matters most for a destination you
  navigate to. Outline `alarm`'s thin white stroke thins out against the accent fill; `alarm.fill`'s
  white knockout face holds.
- **It improves ADR-093's recorded twin instead of being neutral to it.** With `alarm.fill` the block
  reads fill / outline / fill, which leaves `server.rack` as the *only* outline glyph of the three and
  pushes it further from `storefront.fill` — the pair ADR-093 flagged as reading like variants of one
  icon. The earlier draft dismissed this rhythm as "odd" from a 5× sheet; at real pixels it is the
  strongest argument for the choice.
- **It weight-matches `storefront.fill`**, so no row looks lighter than the block it belongs to.

Semantically it needs no learning: a thing that goes off at a time you set is what an automation *is*.
The residual cost, recorded rather than waved away: an alarm clock carries a mild notification
connotation, and Clinic already uses `bell.slash` for per-session mute. They are different marks in
different places — a clock-with-ears in a nav row versus a bell on a session-row badge, never adjacent
— but if notifications ever earn a destination of their own, this is the pairing to re-render.

**`server.rack.fill` does not exist**, so the block cannot be made uniformly filled — SF Symbols gives
`server.rack` no filled variant, and neither `xserve`, `xserve.raid` nor `macpro.gen3.server` is filled
either. The other route to a uniform block — dropping Marketplace to outline `storefront` — was
rendered rather than argued, and **it loses, for ADR-093's own reason**: in an all-outline block
`storefront` and `server.rack` come to share *stroke weight* as well as shape and mass, which is the
one axis on which they were still clearly separated. `storefront.fill`'s solid mass against
`server.rack`'s bands is doing real work, most visibly in dark mode. **The block's mixed weight is
load-bearing, not an inconsistency to tidy**, and `alarm.fill` is the choice that reinforces it.

**Layout: gallery over list-and-detail**, on [[ADR-081 Files Panel Focus Modes]]'s split, the chrome
both existing screens use.

- **Nothing selected → the template gallery**: tiles, each with icon, name, one line of what it does,
  its suggested schedule, and a *Blank automation* tile. A template whose required tool is missing is
  shown greyed with the reason, using [[ADR-086 Tool Discovery and gh Availability]]'s existing
  missing-vs-logged-out split rather than a new mechanism.
- **Something selected → the detail pane**: schedule, target, prompt, the chips, the enable toggle,
  and **run history** — the last runs with state, duration and outcome, each opening the session
  (attach, per ADR-061) or its Replay ([[ADR-059 Replay and Session Details]]). This is the payoff:
  an automation is a stream of readable sessions, not a log file.

**The editor is [[ADR-082 New Session Screen Composer]]'s card, reused.** Same prompt box, same
model / effort chips, same project-icon colour wash, same send affordance turned into *Save*. Added: a
**schedule bar** under the card (preset segmented control that reveals a time picker, a day picker, or
a cron field), and two chips — **permission mode** and **notify on**. The worktree chip is *derived*,
not chosen: it shows what the permission posture implies, and explains itself on hover. Reusing this
card is the whole reason the feature reads as native rather than bolted on, and it is what the user
asked for in the first sentence of the request.

**Notification is per automation**: *Every run* / *Failures and stalls only* (default) / *Never*,
through the ADR-033 pipeline and the existing notification history.

### Templates ship as data

A template is `{ name, icon, blurb, prompt, suggestedSchedule, scope: project|chat, model, effort,
permissionMode, requiredTool? }` in bundled JSON, so adding one is data rather than code and the
gallery can be extended without touching Swift. **Eight ship in v1**, chosen so that half are
read-only reports that cannot stall and half are worth the worktree they take:

| Template | Schedule | Scope | Mode | Needs |
|---|---|---|---|---|
| **Morning triage** — overnight commits, PRs awaiting your review, red CI, as one digest | daily 08:30 | project | plan | `gh` |
| **PR review pass** — review anything opened since the last run | every 6 h | project | plan | `gh` |
| **Session digest** — what you and Claude actually did in this project today | daily 18:00 | project | plan | — |
| **Docs drift** — README and CLAUDE.md against what the code now does | weekly Fri | project | plan | — |
| **Flaky-test hunt** — run the suite N times, report what fails intermittently | nightly | project | acceptEdits | — |
| **Dependency bumps** — safe upgrades on a branch, PR opened | weekly Mon | project | acceptEdits | `gh` |
| **Upstream release watch** — new releases in repos you name | daily | chat | plan | `gh` |
| **Weekly review** — shipped / stuck / next | Fri 16:00 | chat | plan | — |

Deliberately held back rather than shipped thin: TODO sweep, stale-branch prune, changelog draft,
dead-code report, security advisories, standup draft, and an inbox-and-calendar brief over the Gmail
and Calendar MCP servers. The last of these is the most interesting — it would make
[[ADR-093 MCP Server Configuration]] pay off in something you feel daily — and it is held only because
it needs those servers configured before the tile can be anything but greyed out.

### Persistence

`ClinicState.automations: [Automation]` — a handful of small records, well within
[[ADR-021 Persistence]]'s single JSON file. **Run history goes in a sibling `automation-runs.json`**
with per-automation retention, exactly the split ADR-021's own consequence note anticipated for
transcript-derived data: history grows without bound and state must not.

## Consequences
- `ClinicCore/Automations/` gains `CronSchedule` (pure, fixture-tested per
  [[ADR-044 Fixture Strategy]]), `Automation`, `AutomationRun`, `AutomationTemplate` and the bundled
  template JSON. `AutomationService` is a `@MainActor @Observable` store in the app target, per
  [[ADR-043 Concurrency Model]].
- A fifth target, `clinic-wake`, joins `clinic-hook` in `project.yml`. It is the second helper Clinic
  bundles and the first thing it registers with launchd.
- **ADR-017 is amended**: identity is pre-assigned everywhere except `--bg`, where it is learned from
  the short id. **ADR-061 is corrected**: `claude rm` removes the worktree and branch as well as job
  state, and `done` is a terminal state.
- Clinic now depends on `claude` being on `PATH` for a fourth feature. `~/.local/bin` is already in
  `ProcessEnvironment.toolPaths` from ADR-084 and covers it.
- `~/.claude` stays read-only ([[ADR-018 Claude Data Write Policy]]) — every mutation here is argv
  handed to the CLI, and the one file Clinic writes outside its container is its own launchd plist,
  which is not Claude's.
- The stall timeout is the only place Clinic stops a session the user did not ask it to stop. It is
  bounded, per-automation, defaulted to 30 minutes, and always reported in the run history with the
  reason — worth a test that drives a run to `needs_input` and asserts the stop and the record.
- The glyph comparison ADR-093's method calls for was run as part of this ADR rather than
  deferred; `alarm.fill` is settled and the screen header and its empty state use it too.

## As built (2026-09-09)

Five things the implementation settled that the design did not, none of them a deviation from a
decision above:

- **Completion comes from the `claude agents` poll, not from a hook.** The design said hooks give
  Clinic everything, and they give it identity and state — but the *end* of a `--bg` run is not a hook
  event: `SessionEnd` never fires (the process stays resident) and `Stop` is an end-of-turn signal, not
  an end-of-session one. `BackgroundAgentsService` gained an `onRefresh` callback and automations
  reconcile from it, so there is one poll serving both readers rather than two. This is the direct
  payoff of the `done` fix — without it every run would have looked permanently in flight.
- **`CronSchedule.lastDate(atOrBefore:)` exists because catch-up was too slow.** Answering "what was
  the last time this should have run" by stepping forward one fire at a time cost 2.25 s for a
  week-stale `* * * * *`, on every wake, for every automation. Walking days backwards is O(days)
  whatever the expression and made it microseconds. Found by a test with a deliberately tight time
  bound, which is now the guard against regressing to the old shape.
- **`summary()` phrases weekday ranges.** `0 18 * * 1-5` is not a preset, so the first smoke run showed
  three of the eight template tiles speaking raw cron. "Every weekday at 6:00 PM" is not a new preset —
  the picker still has five segments — it is phrasing for a shape that is ordinary English without
  being a segment.
- **`ProcessEnvironment.hasTool` is filesystem-only.** The gallery greys a tile whose CLI is missing;
  doing that by spawning a process per tile would be absurd, so the PATH lookup ADR-086 already
  assembles is now searched directly.
- **The quit-suppression marker records the boot time**, not a date. "Until the next login" is then
  exact rather than a guessed interval, and a fresh boot leaves nothing to expire.

Verified end to end against the real CLI with the production code path (not the UI): argv built as
`claude '<prompt>' --bg -n '<name>' --model haiku --permission-mode plan --settings <hooks>`, no `-w`
in plan mode, launched, and the short id `fbedf704` parsed from stdout turned out to be the prefix of
session `fbedf704-e7dc-4078-a366-4ae31e642658` — the correlation design confirmed in production rather
than only in a fixture. Probes stopped and `claude rm`'d afterwards.

**The editor sheet's layout rule, learned by breaking it.** A SwiftUI sheet sizes to its content, so a
child that refuses to compress is *clipped*, not resized — and because the stack is centred, one
over-wide row clips every other row's leading text too. The behaviour controls began as one `HStack` of
three `.fixedSize()` items needing ~650 pt of labels inside a 620 pt sheet, which made the whole dialog
look broken rather than just that row. They are now one label-and-control pair per `GridRow`; a first
attempt at two pairs per row merely moved the problem, since `Grid` shares width between columns and
truncated the longer menu. The prompt editor also has a fixed height rather than a `maxHeight` range:
with a range it grew to fit a long template prompt and then clipped the last line halfway through, so
the text appeared to bleed into the chips below it.

**The editor's second pass** (2026-09-09, on user feedback that the spacings were inconsistent and the
controls too small). Three changes worth recording because they are rules, not tweaks:

- **One spacing scale, named.** The first version accumulated 6, 8, 10, 14 and 20 pt gaps and read as
  loose. A private `Metrics` enum now holds section / row / inset / sheet, so a gap is a decision rather
  than whatever the previous line happened to use.
- **Sections are captioned.** Four unlabelled blocks never said which control belonged to which idea;
  SCHEDULE and BEHAVIOUR cost two lines and remove the question. Controls move to `.large`.
- **The project picker is a popover, not a `Menu`.** User: *"Project picker could include their icons."*
  It cannot, as a menu — macOS menu items render a title and a system image only, so a project's
  generated icon ([[ADR-076 Project Icon Generation]]) has nowhere to go. The popover shows
  `ProjectIcon` at 24 pt, the name, and the abbreviated path, which is what actually separates two
  projects whose folders share a name; Chat sits at the top with its own explanation. Rows needed their
  own hover state — a list of plain buttons that do not light up reads as disabled.

**The placeholder, and why copying beats re-deriving.** The editor's placeholder was overlaid on the
*padded container* in a `ZStack` and nudged with a guessed `.padding(.top, 8)`, so it sat above and left
of the typed text. [[ADR-082 New Session Screen Composer]] had already solved this exactly: the
placeholder rides *inside* the `TextEditor`, before any padding, offset only by the 5 pt
`NSTextContainer` line-fragment inset that SwiftUI does not expose. Copied verbatim, and verified the
way ADR-082 verified its own — the placeholder and the same string typed now occupy identical pixels
(`x 1420…1644, y 696…716`, same width and height, at every luminance threshold).

Two confounds are worth recording, because both look exactly like misalignment and neither is: the
**focus ring** appears only in the empty state (`promptFocused` is true when the prompt is empty) and
adds ink at the card edge, and the **text caret** sits at the text origin, extending above and below the
glyphs and 3 px to their left. Measured naively, the empty state therefore reads as starting higher and
further left. The tell is the *right* edge of the ink box, which matched all along.

Not yet built, and deliberately called out rather than left to be discovered: the run-history rows can
open a run's session but there is no Replay deep link yet; `keepRuns` is enforced only when auto-prune
is on, since otherwise removal is always offered rather than automatic.
