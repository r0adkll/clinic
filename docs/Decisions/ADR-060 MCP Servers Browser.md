---
status: superseded by ADR-093
date: 2026-09-07
tags: [adr, mcp, ui, milestone-3]
---
# ADR-060: MCP servers browser

## Context
Collins shows a read-only view of every MCP server configured in `~/.claude.json`, global and per project. Verified shape: top-level `mcpServers` (name → `{type, url}` for HTTP/SSE or `{command, args, env}` for stdio) and `projects[<path>].mcpServers` with the same shape, plus `enabledMcpjsonServers` / `disabledMcpjsonServers` lists that refer to a project's `.mcp.json`.

## Decision
- `MCPServersConfig` (ClinicCore) reads `~/.claude.json` (honouring `CLAUDE_CONFIG_DIR`'s sibling file) and, for each project path, its `.mcp.json` when present. Env is reported as variable names only; values never leave the file.
- A sheet (View → MCP Servers…, ⌘⇧M) lists **Global**, then one section per project that has servers, each row with name, transport (stdio/http/sse), command or URL, and enabled/disabled state from the project lists. Clinic's own per-session server is noted at the top as "added per session by Clinic".
- Read-only; no editing.

## Consequences
- Nothing new is persisted. Parsing is tolerant of unknown keys.
