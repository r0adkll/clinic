---
status: accepted
date: 2026-09-07
tags: [adr, mcp, architecture, milestone-3]
---
# ADR-056: Session MCP tools

## Context
Collins exposes 13 tools to the agent through `--mcp-config` and a stdio shim that relays to the app over a Unix socket, identifying the session by the shim's process ancestry. Clinic pre-assigns session ids ([[ADR-017 Session Identity]]), so identity can travel in the config instead.

## Decision
- **Transport**: every Clinic launch adds `--mcp-config ~/Library/Application Support/Clinic/mcp/<session-id>.json`, a file naming one stdio server: the bundled `clinic-hook` binary in `mcp` mode with the socket path and session id as arguments. The shim speaks MCP (JSON-RPC 2.0 over stdio: `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`) and relays `tools/list` and `tools/call` to Clinic's `mcp.sock` as one NDJSON request/response per connection, tagged with the session id. Clinic answers from the main actor with a 15 s timeout; a tool the user has switched off is not listed.
- **Tools (milestone 3)**: `set_session_title(title)`, `notify_user(message, urgency)`, `show_image(path, caption)`, `read_terminal(lines)`, `run_in_terminal(command)` (in the tab's shell panel, never the agent surface), `attach_pr(url)`, `start_session(prompt, directory, model)` (opens a sibling session in a background tab). Deferred until their pages exist: `show_diff`, `annotate_diff`, `highlight_diff`, `clear_diff_marks`, `open_in_editor`.
- **Attachments**: `show_image` records an attachment on the session (path, caption, time) in Clinic state and opens the attachments panel (right column, ⌘⇧I) with a gallery and a lightbox. Transcript-mentioned images are not scanned in this milestone.
- **Preferences**: a switch per tool under a "Session tools" group; all on by default except `run_in_terminal` (off, since it executes commands).
- Not now: MCP resources/prompts, streaming results, per-project tool policies.

## Consequences
- `clinic-hook` becomes a two-mode helper (hook relay, MCP shim); it stays dependency-free and always exits cleanly.
- Sessions resumed outside Clinic never see the tools (no config), which is consistent with [[ADR-047 No Global Hook]].
