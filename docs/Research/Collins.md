---
tags: [research, collins, prior-art]
date: 2026-09-07
source: https://github.com/episode6/collins
---
# Collins (episode6/collins) — research

## What it is
"A vibecoded, native GTK4/libadwaita agentic development environment to manage, orchestrate and complement all your Claude Code sessions." Forked Aug 2026 from `r4nd3l/agent-session-manager`, rebranded Claude-only. Entirely written by Claude Code.

- **Stack**: Python ≥3.10 + PyGObject, GTK4 ≥4.10, libadwaita ≥1.5, **VTE** (GTK4 build) for terminals, GtkSourceView 5 for editor/diff, markdown-it-py, optional libspelling and GStreamer.
- **Platform**: Linux-only. Their own docs: "VTE is the deciding factor: it's the only production-grade embeddable terminal on Linux." Distributed via PPA, COPR, .deb, .rpm, PyPI.
- **Size**: ~100 modules, ~37k+ lines. `window.py` 350 KB, `terminal.py` 298 KB, `diffview.py` 168 KB, `app.py` 158 KB, `sidebar.py` 148 KB.
- **Maturity**: 1 star, GPL-3.0-or-later, created 2026-07-25, last push 2026-09-07, ~586 commits, releases v0.1.0–v0.1.2, "Alpha". Roadmap: Flathub, AUR, "a better native chat beyond the terminal".
- Docs: https://episode6.github.io/collins/

## Feature inventory

### Sidebar / session discovery
- Scans `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`; groups by project. **Favorites** pinned; **Chats** virtual project (scratch dirs).
- Live updates via file monitor on the projects dir (debounced), threaded scans.
- Drag-reorder projects; per-project expand/collapse persisted.
- Search (name, project, preview, id); quick switcher `Ctrl+K`.
- Row states: tab open (filled guide line); **yellow** detached (`/bg`); **red** interrupted; **blue barber pole** working; **green pulse** unread.
- PR status mark per row via `gh` (draft/open/merged/closed + failed checks/conflicts/unanswered comments).
- Custom project icons (`project-icon.svg`), "Generate Icon" via headless `claude -p`.
- Project header menu: new session (here / new window / worktree), git pull, checkout main, open on GitHub, open in…, archive, remove.
- Session context menu: open, open in Ghostty, fork (`--fork-session`), rename, regenerate name, favorite, details, replay, copy id, export Markdown, reveal transcript, archive, trash, delete, move to new window, rename to match PR, repair link.
- Bulk select mode; auto-delete archived after N period; archive mirrored to claude.ai via undocumented endpoint.
- **Usage panel** (5h, weekly, Opus weekly, extra usage) from `/api/oauth/usage` with the CLI OAuth token; polls every 5 min.

### Session tabs / terminal
- Each session = tab with a VTE running `$SHELL`, then `claude --resume <id> --mcp-config <file>` is *typed in* (aliases/env apply; user drops to shell when claude exits). Resume cwd = last cwd in transcript (worktree-aware). Detached → `claude attach <job-id>`.
- Tab bar hidden by default; window title = active session; sidebar is the navigation.
- Footer: live cwd, git branch, **model chip** (sends `/model`), **effort chip** (`/effort`), PR chips, panel/git/editor toggles, user "footer apps".
- Find, zoom, easy copy/paste (Ctrl+C copies if selection else SIGINT), Shift+Enter newline.
- Close flows: graceful (`Ctrl+C Ctrl+C`), `/bg` background, keep-running-hidden.
- Multiple windows share state; a session runs in exactly one tab.
- Env spoof on agent tab: `ConEmuANSI=ON`, `TERM_PROGRAM=kitty` so the CLI emits OSC 9;4 progress.

### Worktrees
- Global + per-project "new sessions in worktree"; launches with `claude -w`. Maps `<repo>/.claude/worktrees/<name>` → `<repo>` for grouping.
- Recreates a deleted worktree on resume from the `worktree-state` transcript record.
- Detects `-w` failure on screen and retries without.
- Archive: ask/always/never trash the worktree, with undo.
- Writes folder trust into `~/.claude.json` before `-w` launch (only deliberate write to CLI data).

### Terminal panel
- `Ctrl+J`: extra plain-shell terminals per session, bottom or right, tabs, splits (binary tree of panes), rotate side, maximize, scrollback persisted per tab.
- Dock leaves: agent terminal (never closable) + strips holding pages: `shell`, `pr`, `composer`, `attachments`, `git`. Editor is a separate end slot. Layout persisted per session.

### Prompt composer + new-chat screen
- Multi-line spell-checked box floating over or docked below the terminal; `Ctrl+.`; drafts persist per session; drag/paste images and files; model/effort buttons.
- New-chat screen: first prompt, worktree checkbox, model picker, effort picker (defaults from `~/.claude/settings.json`); passes `--model`/`--effort`; unsent = **Draft** rows.

### Editor panel (`F8`)
GtkSourceView, file tree, quick open, "Agent files" (recently written by the session, from transcript), external reload, follows worktrees, per-session state, pop-out window.

### Git page (`F6`)
Native diff (per-file cards, per-hunk views, split/stacked, word emphasis, image before/after), commit list down to trunk, unstaged/staged, stage/unstage/discard/revert at file/hunk/line via `git apply`, commit + fixup, notes/highlights on hunks (user and agent), vim-ish keys, auto-reload.

### Pull requests (`F7`)
All via `gh`. PRs from transcript `pr-link` records and first-prompt URLs; PR page (markdown body, checks, timeline, files); actions: ready, merge, auto-merge, request Claude review; "send back to session as prompt" for red CI / conflicts / comments.

### Attachments (`Ctrl+'`)
Per-session gallery from `show_image`, transcript mentions, `SendUserFile`; lightbox.

### Notifications
Kinds: `message` (notify_user tool), `bell` (BEL), `finished` (run ended), `update`. Delivery by focus: in-app card + sound when on another tab; desktop notification when unfocused; history only when looking at it. Bell with unread count. Status/tray icon with badge; dock badge; close-to-hide. Update check. Caffeine mode.

### Session MCP tools (13)
`set_session_title`, `open_in_editor`, `show_diff`, `diff_context`, `annotate_diff`, `highlight_diff`, `clear_diff_marks`, `show_image`, `notify_user`, `attach_pr`, `start_session`, `read_terminal`, `run_in_terminal`. Each has a preference switch.

### Session titling
Pre-existing: first 10 words of prompt. New: ≤5-word summary via headless `claude -p --strict-mcp-config --tools "" --model <haiku> --effort low`. Adopts CLI's own `ai-title`/`custom-title`/`agent-name` records. Precedence: manual > CLI title > generated/PR title > first words.

### Other
Replay tab (transcript as chat bubbles), MCP servers browser, export Markdown, session details, model catalog from Models API, login repair, first-launch dialog, i18n, terminal themes, rebindable keys, searchable Preferences.

### Keyboard shortcuts
`Ctrl+Shift+T` new session, `Ctrl+Shift+N` new window, `Ctrl+W` close, `Ctrl+PgUp/PgDn` tabs, `Ctrl+K` switcher, `Ctrl+Shift+A` archive, `Ctrl+Shift+Z` undo archive, `Ctrl+J` panel, `Ctrl+;` rotate, `Ctrl+.` composer, `Ctrl+'` attachments, `F6` git, `F7` PR, `F8` editor, `Ctrl+Shift+O` quick open, `F9` sidebar, `Ctrl+Shift+B` notifications, `Ctrl+,` prefs.

## Architecture

### Talking to `claude`
PTY only. No SDK, no hooks. Commands: `claude --resume <id> [--fork-session] --mcp-config <path>`, `claude [--model X] [--effort Y] [-w] --mcp-config <path>`, `claude --continue`, `claude attach <job-id>` when `claude agents --json` lists it. Prompts injected by typing then `\r` a beat later; multi-line via bracketed paste. Model/effort via typed slash commands.

### Reading session data
Reads only `~/.claude/projects/**/*.jsonl` (head ≤50 lines/256 KB for cwd/first prompt/timestamp; 64 KB tail for interrupted marker, titles, last cwd, `worktree-state`, `pr-link`, `permissionMode`, `message.model`, `effort`). Also `~/.claude.json` (trust, MCP servers), `~/.claude/.credentials.json` (OAuth token), `~/.claude/settings.json`, `~/.claude/jobs/` (wake-up for background-agent polling).

### Transcript resolver
A fresh tab has no id until the CLI writes a transcript; polls the launch cwd every 1.5 s for a new `.jsonl`, following into a `-w` worktree.

### State detection (sources in trust order)
1. **OSC 9;4 progress** — the CLI's own busy/clear; clear arms a 3 s grace because the CLI blips between tool calls.
2. **Spinner watch** — first-column motion between screen samples.
3. **Redraw events** filtered by an echo gate, with idle timeout.
4. **Process tree** — live descendants under the agent minus a persisted "plumbing baseline" (MCP servers).
5. **`claude agents --json`** busy status for attached background agents.
- **Waiting for input** read off the screen: cursor line starts with `❯` + NBSP, cursor at column 2, tail empty/dim (ghost text via SGR 2). Permission dialogs draw a different marker.
- **Interrupted** = last transcript line contains `[Request interrupted by user`. **Detached** = id in `claude agents --json`.
- Busy→idle edge flags unread, refreshes PRs, fires "finished".

### MCP callback channel
`--mcp-config` names a stdio shim that relays `tools/list`/`tools/call` as NDJSON over a Unix socket to the app. Session identity: shim pid via `SO_PEERCRED`, walked up the process tree to the owning tab. 15 s timeout, 1 MiB frame cap.

## Persistence
`~/.config/collins/state.json` (atomic write on every mutation): names, generated_names, cli_titles, emojis, favorites, archived(+at), archived_projects, project_worktree, project_order, virtual_projects, expanded_groups, panel_layout (per-session dock tree), editor_states, session_prs, session_attachments, session_drafts, new_chat_drafts, process_baselines, session_forwards, pending_detaches, notifications, settings (large catalogue).
Other: title-scratch dirs, panel scrollback, chats scratch dirs, MCP config file, caches (models, update check, dropped images).
`~/.claude/` is read-only except trash/delete transcript (confirmed) and the trust write.

## UI layout
Single window, 1280×860 default. **Left sidebar** (~300 px): hamburger, search, "Sessions" title, collapse-all, refresh, add-project; FAVORITES, CHATS, project groups (icon + name + count + "+"), session rows (status icon, name, relative time); footer counts; usage panel with four progress bars. **Header bar**: sidebar toggle, editor/composer/new-session buttons, stop/background buttons, centered title = active session, caffeine, bell. **Main**: the terminal (empty state: "No session open"), floating composer button, attachments handle. **Tab footer**: model, effort, cwd, branch, PR chip, toggles. Panels open below/right in tabbed strips; editor as a full-height right column.

Screenshots: `docs/public/img/*.png` in the repo.

## Undocumented CLI surfaces relied on
See `docs/guide/how-it-works.md` in the repo: OSC 9;4 progress under a spoofed `TERM_PROGRAM`, `❯` prompt grammar, transcript record kinds (`worktree-state`, `pr-link`, `ai-title`, `custom-title`, `agent-name`, `bridge-session`), `claude agents --json`, `claude attach`, `/api/oauth/usage`, `/v1/code/sessions/<id>/archive`.
