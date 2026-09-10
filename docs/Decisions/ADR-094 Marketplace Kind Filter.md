---
status: accepted
date: 2026-09-09
tags: [adr, ui, plugins, marketplace]
---
# ADR-094: Filtering the marketplace by what a plugin adds

## Context
[[ADR-084 Plugin Marketplace]] gave Discover a search field, a category menu and a sort menu. Categories
come from each marketplace's own manifest — `development`, `productivity`, `security`, `testing` — which
answers "what domain is this for", never "what *is* this". The catalogue's 293 plugins are a mix of skill
bundles, MCP servers, hook sets and subagent packs, and today they are one undifferentiated list.

User (2026-09-09): "For the marketplace screen, could we add tabs/filters for the type of 'plugins' to
install. Such as Skills, Agents, Commands, MCP, etc."

**Claude Code has no plugin "type" to tab on.** A plugin is a bundle, not a kind: `superpowers` ships 14
skills *and* a hook, `vercel` ships 33 skills, an MCP server and two hooks. The type axis the user is
after is the *component inventory* ADR-084 already parses out of `plugin-catalog-cache.json` and shows
in the detail pane's "What it adds". Measured on the live cache, it is a real axis with real spread:
237 plugins add skills, 124 an MCP server, 57 hooks, 51 commands, 33 agents, 14 LSP servers.

That rules tabs out. Tabs partition; a plugin that is one third of the catalogue's skills *and* an MCP
server would have to be filed under one of them and hidden from the other.

## Decision
- **A row of kind chips, not tabs.** Skills / Agents / Commands / MCP / Hooks / LSP, each with a count,
  under the existing section picker. One chip at a time; clicking the active one, or `All`, clears it.
  A chip means "shows me plugins that add this", which is a filter's promise and not a tab's.
- **The order is `PluginKind`'s declaration order, fixed** — the user's own phrasing, not the
  catalogue's current prevalence. A bar that reshuffles when a marketplace is added is a bar you have
  to re-read every visit.
- **Counts are facet counts**: each chip shows how many of the *current* list it would leave, so search,
  category and the chips compose visibly. A kind nothing in the list has drops out of the bar entirely
  — except the selected one, which stays even at zero, because a chip that is filtering must remain on
  screen to be turned off.
- **The filter spans Discover and Installed**, and the segment labels carry it — "Discover (124) ·
  Installed" while MCP is on. "Show me MCP servers; now which of those do I already have" is one
  question, and losing the filter on the way across would make it two.
- **Every row says what it adds**: the kind glyphs and their counts sit on the row's metadata line, so a
  filtered list explains why each result is in it, and an unfiltered one is scannable by kind without a
  click. The detail pane's "What it adds" headings take the same glyphs.
- **Not persisted.** Like `query`, `category` and `sort`, the chip resets each app run; it is a
  question you are asking now, not a preference.

## Consequences
- `PluginKind` moves the six component kinds into `ClinicCore` as one enum carrying label, detail
  heading and glyph; `PluginComponents.groups` is now keyed by it, so the detail pane and the filter bar
  cannot disagree about what a kind is called.
- Glyphs were chosen at the real 13 pt: MCP is deliberately `server.rack`, the MCP Servers screen's own
  mark ([[ADR-093 MCP Server Configuration]]) — one idea, one glyph. Hooks started as `bolt.horizontal`,
  which renders at that size as an anonymous squiggle; rendered in the bar next to its neighbours it was
  replaced with `bolt`, which reads instantly.
- A plugin whose inventory the catalogue cache does not know reads as adding nothing, so it is absent
  from every kind filter rather than present in all of them. Install state never depends on the cache
  (ADR-084), so this costs discoverability for an uncached plugin, never correctness.
- The chips count plugins while a row's glyphs count components — the same glyph and a number meaning
  two things one row apart. Tooltips say which ("Show only plugins that add skills" / "25 skills"); if
  it reads wrong in daily use, the row inventory is the half to change.
