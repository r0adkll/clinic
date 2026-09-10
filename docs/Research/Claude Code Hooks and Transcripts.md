---
tags: [research, claude-code, hooks, transcripts]
date: 2026-09-07
cli-version: 2.1.263
---
# Claude Code hooks, flags and transcripts — facts for Clinic

Sources: https://code.claude.com/docs/en/hooks.md, hooks-guide.md, sessions.md, agent-view.md, cli-reference.md, plus local experiments on 2026-09-07 (CLI 2.1.263).

## Verified locally (2026-09-07)
- **`--settings '<json>'` hooks merge** with project/user hooks. A `SessionStart` hook from `--settings` and one from `.claude/settings.json` both fired.
- **`--session-id <uuid>` creates a new session** with that id; the transcript is written as `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`. Not resume-only.
- Hook stdin payload observed: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `source` (SessionStart: `startup`), and on Stop also `prompt_id`, `permission_mode`.
- cwd encoding: every non-alphanumeric char → `-` (e.g. `/private/tmp/x` → `-private-tmp-x`).

## Hook events (32)
SessionStart (source: startup/resume/clear/compact/fork), Setup, UserPromptSubmit, UserPromptExpansion, PreToolUse, PermissionRequest, PermissionDenied, PostToolUse, PostToolUseFailure, PostToolBatch, Notification, MessageDisplay, SubagentStart, SubagentStop, TaskCreated, TaskCompleted, Stop (`stop_hook_active`), StopFailure, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged, DirectoryAdded, FileChanged, WorktreeCreate, WorktreeRemove, PreCompact, PostCompact, PreModelSwitch, PostModelSwitch, Elicitation, ElicitationResult, SessionEnd.

Common fields: `session_id`, `prompt_id`, `transcript_path`, `cwd`, `permission_mode`, `effort`, `hook_event_name`.

Verified 2026-09-08 by capturing a real payload (a `UserPromptSubmit` hook that writes stdin to a
file and exits 2, which blocks the prompt so no model call is made): `UserPromptSubmit` carries
exactly `cwd`, `hook_event_name`, `permission_mode`, `prompt`, `prompt_id`, `session_id`,
`transcript_path`. **`prompt` holds the submitted text** — it is what labels a turn in
[[ADR-080 Diff Panel]]. `prompt_id` is the handle a future turn → Replay link would use.

## Notification types (12)
`permission_prompt` (after ~6 s waiting), `idle_prompt` (~60 s idle), `auth_success`, `elicitation_dialog`, `elicitation_url_dialog`, `elicitation_complete`, `elicitation_response`, `agent_needs_input`, `agent_completed`, `quota_auto_resume_fired/stale/disabled`.
"Waiting for user" signals: `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`. Note `PermissionRequest` fires immediately (no 6 s delay) and is the better waiting-for-permission signal.

## Handler types and timeouts
`command` (supports `async: true`, `args: []` exec form), `http` (POST to URL), `mcp_tool`, `prompt`, `agent`. Defaults: command/http 600 s (UserPromptSubmit/model-switch 30 s, MessageDisplay 10 s); **SessionEnd hooks share a 1.5 s budget**. Async command hooks do not block the CLI.

## Relevant flags
`--settings <file-or-json>`, `--session-id <uuid>`, `-n/--name <name>`, `--resume [id]`, `--continue`, `--fork-session`, `--from-pr`, `-w/--worktree [name]`, `--model`, `--effort`, `--permission-mode`, `--mcp-config`, `--strict-mcp-config`, `--bg`, `--bare` (skips hooks!), `--include-hook-events` (stream-json only).
Background sessions: `claude --bg`, `claude agents --json [--all]` (fields: id, sessionId, cwd, kind, state working|needs_input|idle|completed|failed, status running|stopped, waitingFor permission|input|sandbox|dialog, pid, name), `claude attach <id>`, `claude logs/stop/rm/respawn`, `/bg` in session.
Env: `CLAUDE_CONFIG_DIR` (relocates `~/.claude`), `CLAUDE_CODE_PROJECT_DIR_NAME` (v2.1.234+).

## Transcript JSONL (undocumented, internal, may change per release)
Record `type` values seen in a real 2.1.x transcript: `user`, `assistant`, `attachment`, `system`, `progress`, `ai-title` (`aiTitle`), `bridge-session`, `mode`, `permission-mode`, `atis-latch`, `last-prompt` (`lastPrompt`, `leafUuid`), `queue-operation`, `file-history-snapshot`, `file-history-delta`, `cost-state` (`totalCostUSD`, `modelUsage`, `totalLinesAdded/Removed`). Collins additionally relies on `custom-title`, `agent-name`, `worktree-state`, `pr-link`. `user`/`assistant` records carry `cwd`, `gitBranch`, `timestamp`, `sessionId`, `message.model` (assistant), `permissionMode`, `effort`.
Docs warn: "The entry format is internal to Claude Code and changes between versions." Clinic's reader must be tolerant: unknown types ignored, per-field optional decoding, fixtures from real transcripts.

## Not in docs
OSC 9;4 progress emission and `TERM_PROGRAM`-dependent behaviour (Collins relies on it under `TERM_PROGRAM=kitty`). Treat as an optional bonus signal via libghostty's `PROGRESS_REPORT` action, never a requirement.
