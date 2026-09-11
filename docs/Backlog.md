# Backlog

Organised by milestone ([[ADR-024 Milestones and Versioning]]). Milestone 1 scope is [[ADR-013 Milestone 1 Slice]]; build order is [[ADR-039 Milestone 1 Build Order]].

## Milestone 1 — "see all my sessions, open one, know when it wants me" → 0.1.0
1. Repo skeleton: git init, MIT, XcodeGen `project.yml`, Ghostty submodule at v1.3.1, `scripts/build-ghostty.sh` (checks Zig 0.15.2 via `brew install zig@0.15`), `.gitignore`, GitHub Actions (xcframework cache keyed by submodule sha + zig version).
2. GhosttyBridge: module map, `GhosttyApp`, `GhosttyConfig` (user config + override list, ADR-034), `GhosttySurfaceView`, action dispatch (ADR-035), headless smoke test. One window showing one shell.
3. ClinicCore: `Project`, `Session`, `Tab` models (ADR-025); JSONL reader head/tail (ADR-029) with synthetic fixtures (ADR-044); `SessionState` machine (ADR-026) with hook-sequence tests; JSON persistence (ADR-021); `HookEvent` decoding.
4. `clinic-hook` helper + Unix socket server actor (ADR-015); `--settings` JSON generation (ADR-027); pre-assigned session ids (ADR-017).
5. Sidebar (ADR-030, ADR-031, ADR-040); new-session sheet (ADR-032); shell tabs; notifications + dock badge (ADR-033); shortcuts (ADR-036); close/quit/exited flows (ADR-037); launch restoration (ADR-042).

## Milestone 2 — daily-driver polish
- ~~Rename, favorite, archive~~ done → [[ADR-045 Session Overlays UI]]
- ~~Search and quick switcher (Cmd+K)~~ done → [[ADR-045 Session Overlays UI]]
- ~~Footer: cwd, branch, model~~ done (pwd action + hooks)
- ~~Terminal panel~~ single shell below, ⌘J → [[ADR-046 Terminal Panel]]; splits/tabs deferred
- ~~Notification history; per-session mute~~ done (batch 4)
- ~~Preferences window, Reveal Logs~~ done (batch 3)
- ~~Opt-in global hook~~ declined → [[ADR-047 No Global Hook]]
- ~~Tab bar~~ → [[ADR-049 Tab Bar]]; ~~project decoration + actions~~ → [[ADR-050 Project Decoration and Actions]]; ~~Clinic-owned sessions + import~~ → [[ADR-048 Clinic-Owned Sessions]]
- ~~Usage panel~~ → [[ADR-051 Usage Panel]]
- ~~Multiple windows; rebindable shortcuts~~ → [[ADR-072 Multiple Windows]], [[ADR-073 Rebindable Shortcuts]]; tab drag-reorder
- Terminal panel splits/tabs (ADR-046 deferred)
- Sparkle updates, Homebrew cask (ADR-010). Signing scaffold exists (`make release`); needs a Developer ID Application certificate + `Local.xcconfig` team id + `notarytool store-credentials clinic-notary`.

## Milestone 3 — the Collins pages (ordered by what each unlocks)
1. ~~**Git page**~~ done → [[ADR-052 Git Page]], superseded by [[ADR-080 Diff Panel]] (milestone 5)
2. ~~**PR page via `gh`**~~ done → [[ADR-053 Pull Request Page]] (deferred: full GFM tables/alerts/details, image diffs, auto-open on attach, rename to PR title)
3. ~~Prompt composer + new-chat screen + drafts~~ built then removed → [[ADR-055 No Prompt Composer]]
4. ~~**Attachments gallery**~~ minimal panel shipped with batch 4 (`show_image` only; transcript-image scanning deferred)
5. ~~**Session MCP tools**~~ done → [[ADR-056 Session MCP Tools]] (deferred: show_diff/annotate/highlight, open_in_editor)
6. ~~**Editor panel**~~ done → [[ADR-057 Editor Panel]] (deferred: pop-out window, open_in_editor tool, image preview)
7. ~~**Replay** + **Session Details**~~ → [[ADR-059 Replay and Session Details]]; ~~MCP servers browser~~ → [[ADR-060 MCP Servers Browser]]
8. ~~**Background agents**~~ done → [[ADR-061 Background Agents]] (deferred: `--bg` from the New Session sheet, respawn)
9. ~~**Polish**~~ done → [[ADR-074 Sidebar Multi-Select]], [[ADR-073 Rebindable Shortcuts]], [[ADR-072 Multiple Windows]], [[ADR-075 Caffeine Mode]]

## Milestone 4 — session & project management parity (see [[Collins Feature Gap]])
1. ~~Project groups~~ done → [[ADR-062 Project Groups]]
2. ~~Session lifecycle~~ done → [[ADR-063 Session Lifecycle Controls]]
3. ~~Model & effort switching~~ done → [[ADR-064 Model and Effort Switching]]
4. ~~Repo upkeep~~ done → [[ADR-065 Repo Upkeep]]
5. ~~Attention~~ done → [[ADR-066 Attention]]
6. ~~Menu bar status item~~ done → [[ADR-067 Menu Bar Status Item]]
7. ~~Chats~~ done → [[ADR-068 Chats]]
8. ~~Keep Running (hide window) + quit behaviour~~ done → [[ADR-069 Keep Running and Quit Behaviour]]
- Later: project title generation (headless `claude -p`; icons done, [[ADR-076 Project Icon Generation]]), i18n, second agent adapter (ADR-004)

## Before tagging 0.1.0
- ~~`initial_input` echo above the prompt~~ fixed: typed at the first prompt via `sendLine`.
- Untrusted folders show Claude's trust prompt inside the terminal (expected per ADR-018); the row stays `launching` until answered.
- ~~Unified log empty~~ it was a fish alias; use `/usr/bin/log`.
- ~~Sidebar selection for unopened rows~~ fixed.
- ~~Xcode scheme test action~~ `make test` runs both package suites instead.
- Verify by hand: working → finished notification in a *real* conversation (synthetic hooks verified); ⌘W close sheet; Resume after `claude` exits. (Quit sheet verified.)
- ~~Developer ID certificate, notarytool profile, `make release`~~ done (first notarized build 2026-09-08); still open: tag v0.1.0 + GitHub release with the zip, Sparkle, Homebrew cask (ADR-010).
- Smoke instances: run with `CLINIC_APP_SUPPORT=<short dir>` (own sockets/state) — a second instance on the default dir steals the running app's sockets.
- Clean the throwaway test sessions (hooktest project, `New session` rows, detached agent de9b277b).
- One-off `ghostty_surface_new` OutOfMemory seen right after a rapid relaunch; retry + alert added. Watch for recurrence.

## Open research
- ~~`CwdChanged` for footer cwd~~ moot: footer follows libghostty's `pwd` action (shell integration).
- Bump to Ghostty 1.4 when tagged (ADR-014).

## Milestone 5 — the diff panel
The git pane becomes a read-only, multi-scope diff reader → [[ADR-080 Diff Panel]].
1. **Turn snapshots** (ClinicCore): `SnapshotStore` actor, `GitRepository.snapshotTree()` /
   `diff(from:to:)`, `TurnSnapshot` + persistence, tests against synthetic repos ([[ADR-044 Fixture Strategy]]).
2. **Hook wiring**: `HookEvent.prompt`; SessionStart/UserPromptSubmit/Stop/SessionEnd drive the store;
   retention sweep + Preferences → Diagnostics size and Clear button.
3. **`DiffPanelModel`** with the scope enum (turn / session / working tree / branch), replacing `GitPageModel`.
4. **`DiffScrollView`** + file rail; `DiffView` generalised to `[UnifiedDiffFile]`; PR page Files tab adopts it.
5. **Pane rename** `.git` → `.diff`, menus, shortcut editor section; delete the staging and commit UI.
- Deferred: reviewed-mark on turns, turn → Replay link, `show_diff` / `annotate_diff` ([[ADR-056 Session MCP Tools]]),
  split view, word emphasis, image diffs.

## Milestone 6 — the marketplace
A screen for finding and installing Claude Code plugins → [[ADR-084 Plugin Marketplace]].
1. **`ClinicCore/Plugins`**: `PluginCatalog` (pure parsers over `claude plugin list --json --available`,
   `marketplace.json`, `plugin-catalog-cache.json`, `blocklist.json`) and `PluginService` (actor over
   the `claude plugin` CLI, shaped like `GitHubService`), with fixture tests ([[ADR-044 Fixture Strategy]]).
2. **Sidebar navigation row** above the project list and its toolbar; ⌘⌥M and a View menu item.
3. **`MarketplaceScreen`**: Discover / Installed / Marketplaces, list-plus-detail, one confirmation
   sheet showing the exact argv before any mutation.
- Deferred: **skills.sh** — its API needs a Vercel OIDC token and `npx skills` prints prose, not JSON;
  needs a key-free API or a `--json` mode, and its own ADR. Also deferred: project/local install scope,
  update-available badges, plugin search across marketplaces not yet added.

## Milestone 7 — automations — **built 2026-09-09**
Scheduled sessions that run a saved prompt on a cron → [[ADR-095 Automations]]. Steps 1–6 all done;
deferred below.
1. ~~**`ClinicCore/Automations`**: `CronSchedule` (five-field parser + bounded next-fire walk, pure
   Foundation, fixture-tested), `Automation`, `AutomationRun`, `AutomationTemplate` + the bundled
   template JSON.
2. ~~**Launcher**: `--bg` argv builder on `ClaudeLaunch`, short-id parse from stdout, bind to the next
   matching `SessionStart`. Fix `BackgroundAgent.isRunning` (`done` is terminal) and correct ADR-061's
   note that `claude rm` also removes the worktree and branch.~~
3. ~~**`AutomationService`**: one timer over the next due automation, catch-up policy (run once / skip),
   overlap skip, stall timeout, reaping via `claude rm` with the clean-worktree fast path.~~
4. ~~**Sidebar navigation row** under MCP Servers with `alarm.fill` (settled by the render comparison,
   2026-09-09), ⌘⌥A and a View menu item.~~
5. ~~**`AutomationsScreen`**: template gallery / list-plus-detail with run history; the editor is
   ADR-082's composer card plus a schedule bar and permission-mode and notify chips.~~
6. ~~**`clinic-wake`** helper target + bundled `SMAppService.agent` plist behind the *Run automations when
   Clinic isn't open* preference, with the quit-suppression marker. *Launch at Login* alongside.~~
- Deferred: Replay deep link from a run row; `keepRuns` enforcement without auto-prune; a template
  gallery search. Deferred templates: TODO sweep, stale-branch prune, changelog draft, dead-code report, security
  advisories, standup draft, and the Gmail/Calendar inbox brief (needs those MCP servers configured
  before its tile is anything but greyed out).

## Milestone 8 — tasks — **built 2026-09-10** (steps 1–5, branch `feature/tasks`)
Issues from every project's GitHub repository, in one screen that starts sessions →
[[ADR-112 Tasks Screen]], [[ADR-113 Work Item Providers and Sources]], [[ADR-114 Starting A Session From A Task]].
1. **`ClinicCore/WorkItems`**: `WorkItem`, `WorkItemRef`, `WorkItemSource`, `WorkItemProvider`,
   `WorkItemFilter` (pure filter/sort/count), `WorkItemCache`; `GitHubWorkItemProvider` over new
   `GitHubService` issue operations (paginated GraphQL list, repo resolution, mention search, detail);
   fixture tests.
2. **`TasksStore`**: source resolution + overrides, cache load, refresh while visible (300 s, ≤ 4 `gh`
   at once), closed on demand, detail on selection, `lastViewed`.
3. **`TasksScreen`**: nav row (first, ⌥⌘T), scope column, list with filters/search/sort/group, footer.
4. **Detail pane**: native header + one scrolling thread web view.
5. **Start Session**: pre-filled composer, ⌘↩ immediate, `workItemLinks`, Show Task, Session Details row.
- Deferred: editable prompt template (+ a Settings pane); issue types, sub-issues, Projects (v2)
  fields; hide/snooze/pin; Tasks in ⌘K and the menu bar item; **attach an issue from the composer**
  (the reverse hand-off; the project's suggested tasks can be attached since
  [[ADR-117 The Composer Suggests Tasks]], an arbitrary issue by search still can't); GitLab (`glab`)
  and Linear providers; write actions (close, assign, comment).
- Found on the way (2026-09-10): automations still launch `-w` with plain `hooks.json`, so they
  ignore the worktree base setting ([[ADR-118 Where A Worktree Branches From]]). Give an automation
  a base, or make it follow its project's.
- ~~Found on the way: the PR panel's link policy (ADR-090) never ran.~~ Fixed 2026-09-10 → [[ADR-115 GitHub HTML Navigation Is Enforced]].

## Milestone 9 — run configurations — **built 2026-09-11** (steps 1–7, uncommitted on `main`)
Run a project's targets from Clinic → [[ADR-122 Projects Have Run Configurations]].
1. ~~**`ClinicCore/Run`**: model, file, checkout rules, launch wrapper, trust, prompts; importer and
   detector; `RunTests`.~~
2. ~~**`RunStore` + surfaces**, stop escalation, restart, exit codes via the wrapper's status file.~~
3. ~~**Run pane** owned by the checkout, re-parented between hosts; header band and failure bar.~~
4. ~~**Controls**: the option-A toolbar pill, Run menu, ⌘R / ⌃⌘. / ⌃⌘R, project menu *Run ▸*,
   notifications, quit prompt.~~
5. ~~**Editor sheet**, **Set Up with Claude…**~~
6. ~~**Import** and **detection**.~~
7. ~~**Sessions**: *Fix with Claude*, the four MCP tools behind the trust rule, re-run after a turn.~~
- Not verified on screen: the toolbar's own menu and the menu bar's Run menu (no smoke run can open
  a menu), *Fix with Claude* (needs a live session), the MCP tools, re-run after a turn, a run shown
  in two windows, the project menu's *Run ▸*, and the notification when a run ends off screen.
- Known: every run's output starts with `login`'s *Last login:* line unless `~/.hushlogin` exists.
  Livewire's `hotRunJvm` is not detected, because Compose now bundles hot reload without a plugin line.
- ~~Destination picker~~ built → [[ADR-124 Runs Get A Device Ready]] (Android devices and emulators, iOS simulators). Not yet seen in the app: the display was asleep during the check.
- Deferred: physical iOS devices; re-run on file change; history; ⌘K and
  status item entries; sidebar running mark; output links; sequential compounds.
