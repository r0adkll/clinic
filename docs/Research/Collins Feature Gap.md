---
tags: [research, collins, roadmap]
date: 2026-09-07
source: https://episode6.github.io/collins/guide/features
---
# Collins feature gap (project & session management first)

Legend: ✅ done · 🟡 partial/different by design · ❌ missing. Decisions that shape the gap: [[ADR-018 Claude Data Write Policy]] (no writes to `~/.claude`), [[ADR-031 Session Naming Precedence]] (no headless `claude -p`), [[ADR-048 Clinic-Owned Sessions]].

## Sidebar
| Collins | Clinic |
|---|---|
| Every session under `~/.claude/projects`, grouped by project | 🟡 owned sessions only, import via ⌘K (ADR-048, by choice) |
| Click project header → new session there | 🟡 hover "+" and menu; header click does nothing |
| Fold/unfold groups (remembered), collapse-all/expand-all | ❌ |
| Drag project headers to reorder, persisted | ❌ (`projectOrder` field exists, unused) |
| Favorites section | ✅ |
| Compact rows; optional second line with folder path | 🟡 rows yes; folder-path option no |
| Sessions sorted by creation time (rows don't jump) | 🟡 sorted by last activity (ADR-040) |
| Hover actions: archive; stop + background on open tabs | 🟡 close/archive/star; no stop (graceful), no background |
| Aggregated PR status mark per session | ❌ (PR milestone) |
| Custom `project-icon.svg`; Generate Icon via Claude | 🟡 icons yes; generation deferred |
| Git pull / Checkout main from header menu | ❌ |
| Live updates, "New Thread" placeholder | ✅ |
| Header refresh button | ❌ (minor) |
| Search box; ⌘K switcher | ✅ |
| Add a project (+), trust prompt up front | 🟡 folder picker in New Session sheet; no sidebar "+"; trust answered in terminal |
| Claude usage panel | ✅ (5-min poll; no retry-after-failure) |
| Auto-generated titles (headless `claude -p`), Regenerate name | ❌ by ADR-031; follows CLI titles ✅ |

## Sessions & terminals
| Collins | Clinic |
|---|---|
| Resume in last cwd, worktree-aware | ✅ |
| Re-attach detached (`claude attach`) | ❌ (background agents milestone) |
| Unread marks, open tabs stay open | ✅ |
| Footer: model, effort, cwd, branch (→ git page), panel/git/editor buttons | 🟡 model/cwd/branch/pid; no effort, no buttons |
| Footer apps (open cwd in chosen apps) | ❌ |
| Tab bar (toggle) | ✅ (on by default) |
| Model menu (Models API + `/model`), effort menu (`/effort`) | ❌ |
| PR chips + PR page | ❌ (PR milestone) |
| Rename, copy ID, fork (`--fork-session`) | 🟡 rename/copy yes; fork no |
| In-terminal search | ❌ |
| Easy copy & paste | ✅ (native ⌘C/⌘V via Ghostty config) |
| Close asks agent to exit cleanly (Ctrl+C ×2) or background it; header stop/background buttons | 🟡 confirm sheet then kill; no graceful stop, no background |
| Keep Running (hide window); quit behaviour pref | ❌ |
| Window title, resizable sidebar, reopen last session | ✅ |

## Knowing what's happening
| Collins | Clinic |
|---|---|
| `notify_user` tool notifications | ❌ (MCP tools milestone) |
| In-app card when in another tab; desktop notification when away; nothing when looking at it | 🟡 system notification when not front-and-selected; no in-app card |
| Bells from other sessions as notifications; visual bell | ❌ (beep only) |
| Update check (GitHub releases) | ❌ |
| Header bell + history sheet, unread/earlier, mark read/remove | 🟡 popover history, mark-all/clear; no per-row remove |
| Session details dialog | ❌ |
| Replay transcript | ❌ (later milestone) |
| MCP servers browser | ❌ |
| Rebindable keyboard bindings | ✅ ADR-073 |
| Status icon (tray) with badge + session jump menu | ❌ (macOS: NSStatusItem) |

## Starting sessions
| Collins | Clinic |
|---|---|
| New session in the visible project without a dialog; menu with Continue last, worktree-inverted, New chat | 🟡 sheet every time; worktree toggle yes; no Continue, no Chats |
| Chats virtual project (scratch folder, pre-trusted) | ❌ |
| New-chat screen (composer, model/effort pickers, Empty Session) | ❌ (composer milestone) |
| Drafts | ❌ (composer milestone) |
| Worktree per project pin; one-off inversion | ✅ |
| Folder trust asked up front | ❌ (ADR-018; trust answered inside the terminal) |

## Bulk actions & housekeeping
| Collins | Clinic |
|---|---|
| Select mode (bulk open/star/archive/trash) | ✅ ADR-074 (no trash) |
| Archive (+show archived), archive whole project, archive closes tab | 🟡 archive yes; remove project hides; no archive-project |
| Worktree trash on archive, with Undo | ❌ |
| Archive on claude.ai (undocumented endpoint) | ❌ (skip) |
| Delete archived sessions; auto-delete after N; move to trash; delete permanently | ❌ (ADR-018 forbids; would need an ADR) |
| Export as Markdown | ❌ |
| Reveal transcript, Open In…, Open in new window, Rename to match PR, Repair link, Open in Ghostty | 🟡 reveal + Finder; rest missing |
| Caffeine mode | ✅ ADR-075, ADR-119 (persisted; Always On or Agent Based) |
| Multiple windows; move session to new window | ✅ ADR-072 |

## Proposed milestone 3 — session & project management parity
Ordered by daily value; each item is small enough for one batch.
1. **Project groups**: collapse/expand per project (persisted), collapse-all; drag-reorder projects (persisted `projectOrder`); click header = new session; sidebar "+" add project; "Show folder paths" option; sort choice (creation vs activity).
2. **Session lifecycle controls**: graceful Stop (Ctrl+C ×2 typed into the surface) as hover/header/menu action; close sheet offers Stop-and-close vs Cancel; Fork session; Continue last session in a folder (`claude --continue`); Open in Ghostty; Open In… (app picker); Session Details dialog (counts, models, cost from transcript); Export as Markdown.
3. **Model & effort switching** from the footer: static alias menus that type `/model` and `/effort` when the session is idle; footer buttons for panel.
4. **Repo upkeep**: Git pull and Checkout main in the project menu with error sheets; Archive project; Trash worktree on archive with Undo.
5. **Attention**: in-app notification card when in another tab; bells from other sessions; "Announce finished runs" toggle (already default); per-row remove in history; update check against GitHub releases.
6. **Menu bar status item**: unread badge, working/unread glyph, jump-to-session list, Show Clinic, Quit.
7. **Chats** virtual project with scratch folders.
8. **Keep Running (hide window)** and the quit-behaviour preference.

Deferred with reasons: headless title generation / regenerate / icon generation (spend quota; ADR-031), transcript deletion & auto-delete (ADR-018), claude.ai archive sync (undocumented endpoint), PR marks & chips (PR milestone), composer/new-chat/drafts (composer milestone), background/detached agents (own milestone), select mode, rebindable keys, multiple windows, caffeine.
