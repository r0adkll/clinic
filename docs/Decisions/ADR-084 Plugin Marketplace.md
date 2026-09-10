---
status: accepted
date: 2026-09-08
amends: ADR-018
tags: [adr, ui, plugins, marketplace, milestone-6]
---
# ADR-084: Plugin marketplace

## Context
Clinic manages sessions but says nothing about what those sessions can *do*. Installing a plugin
today means leaving the app for a terminal and remembering `claude plugin marketplace add …`.
User (2026-09-08): "add a 'Marketplace' feature for easily installing claude plugins and other
skills (like those from https://www.skills.sh/, or github). It should be its own screen, and a
navigation item (with icon) in the sidebar above the projects list and its actions bar."

Two facts, both verified before deciding:

- **The `claude` CLI already exposes the whole surface.** `claude plugin list --json --available`
  returns installed plugins *and* the full catalogue of every added marketplace in ~150 ms;
  `install`, `uninstall`, `enable`, `disable`, `update` and `marketplace add|remove|update|list`
  cover every mutation. Mutating subcommands require `-y` when stdout is not a TTY.
- **The metadata worth showing is already on disk.** `~/.claude/plugins/` holds
  `known_marketplaces.json`, each marketplace's `marketplace.json` (author, category, homepage),
  `plugin-catalog-cache.json` (install counts, component inventory, per-model token cost) and
  `blocklist.json`. Nothing here needs the network or a credential.

**skills.sh cannot be a v1 source.** Its documented `/api/v1/skills*` endpoints answer
`401 authentication_required` and want a Vercel OIDC token — unobtainable from a Mac app. Its
`npx skills` CLI does work headlessly (`skills find <query>`, `skills add owner/repo@skill`) but
prints ANSI-coloured prose rather than JSON, and drags in a node dependency. Offered to the user
with those costs; they chose Claude plugins only.

GitHub is not a separate source either: `claude plugin marketplace add owner/repo` accepts any repo
carrying a marketplace manifest, so "install from GitHub" is the same path with a different name.

## Decision
- **A Marketplace screen**, reached from a permanent navigation row pinned above the project list
  and its icon toolbar in the sidebar (`storefront.fill`, in ADR-077's 22 pt glyph column). Ten
  candidates were rendered at the real 13 pt size in both states and compared; `puzzlepiece` was
  rejected because the app already uses it for the plugin rows themselves — the destination should
  not wear its own contents' icon — and the shopping glyphs (`bag`, `cart`, `basket`, `tag`) because
  nothing here is bought.
  Its metrics are a nav row's, not a project header's. It first borrowed the header's 12 pt
  disclosure column and 22 pt glyph column so its label would line up with a project name; both are
  gone. This row is not part of the project outline — the toolbar and divider separate it — so
  indenting it to clear a chevron it does not have was the only thing that padding bought, and it
  pushed the label 26 pt off the sidebar's left edge. Now: an 18×16 glyph box, 6 pt gaps, 6 pt
  interior and 4 pt vertical padding, in a pill whose 10 pt outer inset lines its *box* up with the
  search field above and the session rows' selection fills. A 24 pt row against a header's 28 — 2 pt
  of vertical padding measured too tight next to the 30 pt search field it sits under. It is a per-window *content mode*, not a tab and not a sheet: it owns no session, so a tab would
  carry a terminal surface it never uses. `WindowState.showingMarketplace` is mutually exclusive
  with `selectedTabId` and `editingDraft`, in the same `didSet` style those two already use on each
  other. Also on the View menu, default ⌘⌥M — beside ⌘⇧M for MCP Servers.
- **Three sections** behind a segmented picker, over the list-plus-detail split ADR-081 established:
  **Discover** (search and category chips across every added marketplace), **Installed**
  (enable / disable / update / uninstall) and **Marketplaces** (add by `owner/repo`, URL or local
  path; update; remove). The detail pane shows description, author, category, homepage, version,
  source, install count, the skills / agents / hooks / MCP-server inventory, the projected always-on
  token cost, and a warning when `blocklist.json` names the plugin, with Anthropic's stated reason.
- **`~/.claude` stays read-only to Clinic — this amends [[ADR-018 Claude Data Write Policy]],
  it does not repeal it.** Clinic writes nothing under `~/.claude`, ever. Every mutation is argv
  handed to the `claude` CLI, which owns those files. Each one is user-initiated and shown in full
  (`claude plugin install foo@bar --scope user -y`) in a confirmation sheet before it runs; a
  failure shows the CLI's own stderr rather than a paraphrase. Editing `installed_plugins.json`,
  `settings.json`'s `enabledPlugins`, or anything else under `~/.claude` directly remains forbidden
  and still needs its own ADR.
- **Reads follow [[ADR-060 MCP Servers Browser]]**: parse Claude's own JSON tolerantly, ignore
  unknown keys, degrade to empty rather than throwing. The CLI's `--json` output is authoritative
  for install state; the on-disk manifests only enrich it, so a cache Claude Code has not written
  yet costs detail, never correctness.
- **Installs are not retroactive.** A plugin installed or toggled here reaches sessions started
  afterwards, not the ones already running. The screen states this rather than implying otherwise.
- **User scope by default.** `--scope user`; project and local scope are deferred until there is a
  reason to choose per project.

## Consequences
- `ClinicCore/Plugins/` gains `PluginCatalog` (pure parsers, fixture-tested) and `PluginService`
  (an actor over the CLI, shaped like `GitHubService` down to the static `arguments(for:)` that
  makes argv a unit test).
- Clinic now depends on `claude` being on `PATH` for one more feature. `ProcessEnvironment.toolPaths`
  prepends only `/opt/homebrew/bin` and `/usr/local/bin`, so a `claude` installed at
  `~/.local/bin/claude` was invisible to a GUI-launched Clinic — which also affected background
  agents ([[ADR-061 Background Agents]]). `~/.local/bin` joins that list.
- skills.sh stays a live want. It needs either a key-free API or a JSON mode in `npx skills`; either
  one is a new ADR, not a silent extension of this screen.
