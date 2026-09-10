---
status: accepted
date: 2026-09-08
amends: "[[ADR-050 Project Decoration and Actions]]"
tags: [adr, ui, projects]
---
# ADR-076: Project icon generation

## Context
[[ADR-050 Project Decoration and Actions]] resolves a project icon from `project-icon.svg|png` → `.clinic/icon.*` → a monogram, and ruled out headless generation ("No headless icon generation"). The backlog kept it as a later item ("project icon / title generation (headless `claude -p`)"). Every project without an icon file therefore shows a coloured letter, which is most of them.

Verified on the pinned CLI: `claude "<prompt>" -p --model sonnet --allowedTools Read,Glob,Grep --permission-mode dontAsk --no-session-persistence --strict-mcp-config` run with the project as cwd reads the README/manifests and returns a bare `<svg>` element in ~8 s. `NSImage(contentsOf:)` renders SVG natively (`_NSSVGImageRep`), so the generated file needs no rasterisation.

## Options
- Generate on first sight of a project — rejected: spends tokens without being asked, and [[ADR-070 Usage Panel Consent]] set the precedent that nothing costly happens unprompted.
- Store the result in Application Support so the repo stays clean — rejected by the user: the icon should travel with the repo like any other project asset.
- Adopt the first result silently — rejected: a model's first sketch is often wrong; a preview costs one sheet.

## Decision
- **Trigger**: *Generate Icon…* in the project menu (header ⋯ and context menu), next to a *Remove Generated Icon* item that is enabled only when `.clinic/icon.svg` exists. Never automatic; one run per press.
- **Generation**: headless `claude -p` in the project directory, prompt-first (the `--mcp-config`/variadic-swallow lesson), read-only tools (`Read,Glob,Grep`), `--permission-mode dontAsk`, `--no-session-persistence` and `--strict-mcp-config` so the run leaves no transcript, needs no approval and loads no MCP servers. Model: `sonnet`, not user-selectable. `stdin` is `/dev/null`; a run is cancellable and gives up after 180 s.
- **Contract**: the model returns one self-contained `<svg viewBox="0 0 64 64">` — rounded-square badge, flat symbol, ≤4 colours, legible at 22 pt. Clinic extracts the element (fenced or bare), then **rejects** anything with `<script>`, `<foreignObject>`, `<image>`, `href`/`xlink:href`, a DOCTYPE or entity declaration, or over 64 KB, and finally requires that `NSImage` renders it. A rejected result is an error, never a saved file.
- **Review**: a sheet with an optional style hint, Generate/Regenerate, the result previewed at 22 pt and 96 pt over both light and dark chips, and Use / Cancel. Nothing is written until *Use*.
- **Storage**: `<project>/.clinic/icon.svg` — the existing ADR-050 lookup path, so resolution order is unchanged (`project-icon.svg|png` still wins). Clinic creates `.clinic/` if needed and touches nothing else; whether the file is committed or ignored is the user's business.

## Consequences
- ADR-050's "No headless icon generation" no longer holds; the rest of ADR-050 stands.
- Generating writes inside the user's repository — the first Clinic feature that does. It is only ever the one file, only on explicit request.
- The icon cache gains explicit invalidation (`ProjectIconCache.invalidate(path:)` bumps an observed revision) so the sidebar, notification card and new-session screen redraw after *Use*.
- Title generation from the same backlog line stays open.
