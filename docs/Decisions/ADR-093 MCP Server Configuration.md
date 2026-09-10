---
status: accepted
date: 2026-09-09
supersedes: ADR-060
tags: [adr, mcp, ui, cli, milestone-6]
---
# ADR-093: Configuring MCP servers

## Context
[[ADR-060 MCP Servers Browser]] gave MCP servers a read-only sheet: ⌘⇧M, a list grouped by scope,
no editing. That was the right call when Clinic wrote nothing outside its own container, but it
leaves the app able to *show* you a misconfigured server and unable to do anything about it.
User (2026-09-09): *"It would be nice to configure local and global MCP servers from within Clinic."*

[[ADR-084 Plugin Marketplace]] already solved the shape of this problem for plugins — read Claude's
files, write through Claude's CLI — so the question is not *whether* that pattern applies but what
the `claude mcp` CLI actually permits. Everything below was verified against the real CLI (a scratch
`CLAUDE_CONFIG_DIR`, nothing touched in `~/.claude.json`) before deciding.

**The CLI covers the whole surface.** `add`, `add-json`, `add-from-claude-desktop`, `remove`, `get`,
`list`, `login`, `logout`, `reset-project-choices`. So [[ADR-018 Claude Data Write Policy]] survives
intact for a second feature: Clinic writes nothing under `~/.claude`, it hands argv to the tool that
owns those files.

Six findings that constrain the design, not just decorate it:

- **`add` refuses to overwrite.** A second `claude mcp add demo …` prints
  `MCP server demo already exists in user config` and exits 1. There is no `claude mcp edit`.
  Editing is therefore remove-then-add, a two-step mutation with a gap in the middle.
- **`add` and `remove` work fine with no TTY and no `-y`**, unlike `plugin install`. The
  confirmation sheet is Clinic's own promise to the user, not a CLI requirement.
- **`mcp list` cannot be the data source.** No `--json`; it health-checks every server (measured
  3.8 s); and it only sees the project matching `cwd`. Reading `~/.claude.json` and each `.mcp.json`
  from disk is instant and sees every project. The CLI's text output is worth parsing for one thing
  only — live status — and only when asked.
- **There is no `disable`.** For `.mcp.json` servers the approval state lives in a project's
  `enabledMcpjsonServers` / `disabledMcpjsonServers`, written only by answering the prompt inside a
  running session; `claude mcp get` reports `⏸ Pending approval (run \`claude\` to approve)`. The
  only CLI lever is `reset-project-choices`, which clears the lot. Clinic cannot build a per-server
  on/off switch without writing `~/.claude.json` directly, which it will not do.
- **`add-json` exists, and every MCP server's README ships a JSON snippet.** This is the highest-value
  affordance available and it costs one subcommand.
- **`mcp login` is interactive** — it opens a browser and waits, or with `--no-browser` prints a URL
  and waits for a pasted redirect. Neither works from a captured pipe.

**Two smaller facts.** Env values are stored in `~/.claude.json` in plaintext and pass through argv
on the way in, so redaction can only ever govern *display*. And `CLAUDE_CONFIG_DIR` puts the config
at `$CLAUDE_CONFIG_DIR/.claude.json` — *inside* the directory, watched being written there — while
`MCPServersConfig.configFileURL` computes a sibling. That is right for the default `~/.claude` and
wrong for every smoke instance; ADR-060's "honouring `CLAUDE_CONFIG_DIR`'s sibling file" was simply
mistaken.

**The vocabulary is a trap.** The user's "local and global" does not map onto Claude Code's three
scopes, two of which are local:

| CLI scope | Where it lives | Who sees it |
|---|---|---|
| `user` | `~/.claude.json` → `mcpServers` | every project of yours |
| `local` (**the CLI default**) | `~/.claude.json` → `projects[path].mcpServers` | one project, only you |
| `project` | `.mcp.json` at the repo root | one project, committed, your team |

A GUI that says "local" inherits the ambiguity, and a GUI that invents its own words breaks the
mapping to the CLI the user will still type. So: keep Claude's scope names, and subtitle each one so
the difference is unmissable — **All projects**, **This project · private**, **This project · shared
via .mcp.json**. Never silently inherit the CLI's `local` default; the scope control opens with no
selection until the user picks.

## Decision

**A screen, not a sheet, reached from its own sidebar nav row.** ADR-060's sheet is retired: it was
a sheet *because* it was read-only, and list-plus-detail-plus-form is more than a modal holds. The
new row sits directly under Marketplace in the pinned navigation block above the project list,
taking [[ADR-084 Plugin Marketplace]]'s row metrics unchanged (18×16 glyph box, 6 pt gaps, 6 pt
interior, 4 pt vertical padding, 10 pt outer inset). ⌘⇧M keeps its meaning and now opens the screen;
Marketplace keeps ⌘⌥M. Also on the View menu.

- **Glyph: `server.rack`** (settled 2026-09-09 by the render comparison this ADR reserved; see the
  amendment below). `network` and `terminal` are out by ADR-084's own rule — the destination must not
  wear its contents' icon, and those two are exactly what the transport badges use on each row.

- **`WindowState` stops growing pairwise.** Three mutually exclusive content modes already cost six
  `didSet` assignments; a fourth would cost twelve. Replace the `showingMarketplace` boolean with
  `var screen: Screen?` (`enum Screen { case marketplace, mcpServers }`), leaving `editingDraft`
  alone — it is mutated through the optional in half a dozen places (`tabs.editingDraft?.prompt = …`)
  and an enum payload would fight that for nothing. Exclusivity stays three-way, and the next screen
  is a new case rather than another round of clearing. `showingMarketplace` survives as a computed
  shim so ADR-084's call sites do not churn. `isShowingScreen` becomes `screen != nil ||
  editingDraft != nil`.

**Layout: a project picker over list-and-detail**, on [[ADR-081 Files Panel Focus Modes]]'s split, the
same chrome the Marketplace screen uses.

- The list shows **All projects** plus the **selected project's two scopes**, and nothing else. The
  picker is populated from `ProjectRoster`, defaults to the project of the front tab, and a
  *Show all projects* toggle reveals ADR-060's full inventory for when you want to audit rather than
  configure. Empty scopes are shown as empty rather than hidden, because "this project has no
  private servers" is the answer to a question people ask.
- Clinic's own per-session server keeps ADR-060's note at the top — it is added by `--mcp-config`
  per launch ([[ADR-056 Session MCP Tools]]), appears in no config file, and is not editable here.
- Each row: name, a transport badge (`terminal` for stdio, `network` for http/sse), the redacted
  command or URL, and for `.mcp.json` entries an approval pill (*Approved* / *Pending* / *Disabled*).
- The detail pane adds env-var and header **names only, never values** — ADR-060's rule, kept — the
  file the definition came from with a Reveal button, and the actions.

**Reads come from disk; the CLI is for writes and for status on demand.** `MCPServersConfig` stays
the reader and is extended with headers and the `.mcp.json` approval state, and its
`configFileURL` is corrected to `$CLAUDE_CONFIG_DIR/.claude.json` with `~/.claude.json` as the
default. Live status (*Connected* / *Needs authentication* / *Pending approval* / *Failed*) comes
from `claude mcp get <name>` run with the project as `cwd`, triggered by selecting a row or a
Refresh button — never on every render, because it is a network health check.

**Adding has two doors, and the second one is the point.**

- **Paste JSON** accepts what a vendor README actually contains — either a bare
  `{"command": …, "args": […]}` body or the full `{"mcpServers": {"name": {…}}}` wrapper, from which
  the name is lifted. It parses into the form for review, then runs `claude mcp add-json <name>
  '<json>' --scope <scope>`. This is how nearly every MCP server documents itself, and typing that
  back into a form by hand is the friction the screen exists to remove.
- **Form**: name, scope, transport, then command + arguments + environment (stdio) or URL + headers
  (http/sse), with key-value rows for env and headers. The name is checked against the chosen
  scope's existing names *before* the command runs, because `add` fails on collision and a
  pre-flight check turns an error into a disabled button.

**A live, redacted command preview sits under both doors**, e.g.
`claude mcp add --scope user hardcover -e API_KEY=•••••• -- hardcover mcp serve`.
This is a deliberate, named deviation from ADR-084's "shown in full": showing an API key in full
would be worse than showing it abbreviated, and `MCPServerEntry.redact` already exists for exactly
this. The redaction is display-only — the real value goes in argv, where it is briefly visible to
`ps`, and then to `~/.claude.json` in plaintext. The screen says so next to any field that takes a
secret rather than implying a safety it cannot provide.

**Editing is remove-then-add, with a rollback.** Because `add` will not clobber:

1. Snapshot the current definition from disk.
2. `claude mcp remove <name> -s <scope>`
3. `claude mcp add …` (or `add-json`)
4. If step 3 fails, re-add the snapshot and show *both* errors — the one that failed and whether the
   restore succeeded.

The confirmation sheet shows both commands, so the two-step nature is visible rather than hidden
behind a Save button. Renaming is the same path. This is the least pleasant part of the design and
it is the CLI's shape, not a choice; if `claude mcp` ever grows an in-place edit, this step goes away
and needs no new ADR.

**What Clinic will not do**, stated on the screen rather than left to be discovered:

- **No enable/disable toggle.** There is no CLI command for it and the only alternative is writing
  `enabledMcpjsonServers` / `disabledMcpjsonServers` in `~/.claude.json`, which ADR-018 forbids. A
  `.mcp.json` server's approval state is *shown*, with the explanation that approval happens the
  first time a session in that project starts. `Reset approval choices…` offers
  `reset-project-choices` for the project, clearly labelled as clearing every choice at once.
- **No revealing secrets.** Env and header values are never read out of the config into the UI.
  Reveal opens the file in Finder and lets the user decide.
- **No direct writes to `~/.claude` or to a `.mcp.json`.** Every mutation is argv, confirmed, and
  its failure is the CLI's own stderr verbatim — `PluginError.plain`'s treatment, reused.

**OAuth runs in a terminal, because that is where interactivity works.** *Log in* / *Log out* on an
http or sse server opens a terminal pane ([[ADR-079 Panel Tabs]]) in the project's tab running
`claude mcp login <name>`, so the browser hand-off and any prompt happen in a real PTY. Capturing
that command's pipes and building a paste-the-redirect-URL field would be a worse version of a
terminal Clinic already has.

**Changes are not retroactive**, exactly as in ADR-084: a session already running keeps the servers
it launched with. The screen states this plainly. It does not attempt to name which running sessions
are affected — Clinic knows their start times and could, but that is a separate idea and not what
makes this screen work.

**Import from Claude Desktop** is a single button running `claude mcp add-from-claude-desktop
--scope user`, shown only on macOS, where it is supported.

**Module shape**, following ADR-084's:
- `ClinicCore/MCP/MCPService` — an actor over the CLI with a static `arguments(for:)` so argv is a
  unit test rather than a live call, and a `displayCommand` that redacts. Mirrors `PluginService`
  down to the environment scrubbing (`CLAUDECODE`, `CLAUDE_CODE_*`, `NO_COLOR`, `CI`).
- `ToolProcess.run` / `runSync` gain a `currentDirectory: URL?` parameter, defaulting to nil. Local
  and project scope are `cwd`-relative, so without it Clinic could only ever configure the directory
  it happens to be running in.
- `MCPServersConfig` gains headers, approval state, the JSON-snippet parser, and the corrected
  config path. Existing `MCPServersConfigTests` extend with fixtures for each.

## Amendment (2026-09-09): the glyph, decided on evidence

This ADR first chose `powerplug.fill` and said plainly that the at-size comparison ADR-084 ran had
*not* been done. It has now been done — ten candidates rendered at the row's real metrics (13 pt in
an 18×16 box, semibold callout label), unselected and accent-filled, and again stacked under
Marketplace as the sidebar actually draws them. User (2026-09-09): *"i wonder if a 'server' icon for
MCP sidebar item would be better?"*

**The original reasoning was wrong on the facts.** `server.rack` does not "mush at 13 pt" — it is the
most legible mark of the whole set, its bands staying distinct in both states, and it reads as
"servers" with no learning at all. `powerplug.fill`, by contrast, collapses into a small blob at this
size: the prongs merge into the body and the plug stops being recognisable as a plug.

**The real objection was one the original never spotted**, and it only appears in the stacked view:
`server.rack` under `storefront.fill` twins it. Both are a rounded box of the same mass with a
divided interior, so the two destinations read as variants of one icon until you read the labels.
`xserve` and `internaldrive.fill` share the fault more strongly.

Weighed against that: `externaldrive.connected.to.line.below` keeps a machine-shaped box but drops a
stem below it, breaking the twin at the cost of reading as "external drive";
`point.3.connected.trianglepath.dotted` is distinct but noisy at 13 pt; `cable.connector` is too
small a mark to carry a row; `wrench.and.screwdriver.fill` matches the screen's own subtitle ("Tools
your sessions can call") and is the most distinct silhouette, but crossed tools is a strong
Settings convention on macOS.

**Decision: `server.rack`.** Unambiguous semantics beat a silhouette similarity that two different
labels resolve on first read and that a user learns exactly once. The similarity is a real cost and
is recorded here rather than waved away — if the pinned nav block ever grows a third box-shaped
destination, this is the constraint to revisit. `powerplug.fill` is retired; the screen header and
its empty state use `server.rack` too.

**Process note worth keeping:** the single-column contact sheet was not enough to decide this. The
fault that mattered was invisible until the candidates were drawn *in their real adjacency*. Render
the neighbours, not just the glyph.

## Consequences
- ADR-060 is superseded: the sheet is gone, its reader survives and grows. The screen still reads
  Claude's JSON tolerantly and degrades to empty rather than throwing.
- `~/.claude` read-only holds for a second feature. ADR-018 has now been amended twice in the same
  direction and never repealed; the invariant is "Clinic writes nothing there", not "Clinic changes
  nothing there".
- The `CLAUDE_CONFIG_DIR` path fix changes what a smoke instance sees. Runs that set that variable
  were reading the real `~/.claude.json` all along, which made the sheet look correct for the wrong
  reason.
- Clinic now depends on `claude` being on `PATH` for a third feature. `~/.local/bin` was added to
  `ProcessEnvironment.toolPaths` for ADR-084 and covers this too.
- The remove-then-add edit is the only place in the app where a user action is two mutations with a
  window between them. It is worth a test that drives the rollback path with a deliberately invalid
  second command.
- Paste-JSON makes the screen useful before the form is finished, which is the order to build them in.
