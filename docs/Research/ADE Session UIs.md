---
tags: [research, architecture, claude, prior-art, harnesses]
date: 2026-10-02
sources: [https://github.com/stablyai/orca, https://github.com/episode6/collins, https://github.com/manaflow-ai/cmux, https://github.com/superset-sh/superset, https://github.com/BloopAI/vibe-kanban, https://github.com/imbue-ai/sculptor, https://github.com/stravu/crystal, https://github.com/getAsterisk/opcode, https://github.com/agentclientprotocol/agent-client-protocol, https://github.com/agentclientprotocol/claude-agent-acp, https://zed.dev/blog/claude-code-via-acp, https://code.claude.com/docs/en/vs-code, https://code.claude.com/docs/en/desktop, https://learn.chatgpt.com/docs/app-server, https://cursor.com/docs/cli/acp]
---
# How other ADEs draw a coding agent

User (2026-10-02): *"Re-rendering in Clinic driven UI is definitely a point. Could you explore other ADEs like
Orca and how they handle this kind of UI with claude code (and potentially other harnesses)"*. Follows
[[Native Session UI]].

Read from source, not READMEs. Shallow clones are at these commits:

| Repo | Commit |
|---|---|
| orca | `de8bffe` |
| collins | `b6e54d2` |
| cmux | `23d3e88` |
| superset | `11b89a6` |
| vibe-kanban | `d5cbb53` |
| sculptor | `f847102` |
| crystal | `1e18e0b` |
| opcode | `d1ca30a` |
| agent-client-protocol | `5cee392` |
| claude-agent-acp | `63aa3b8` |
| codex | `9d2b603` |
| opencode | `c42ae0d` |
| gemini-cli | `fb972b2` |

The VS Code extension was read from its VSIX (Anthropic.claude-code 2.1.287). None of the apps were run.

## The pattern
- **Every vendor's own GUI drives its agent headlessly and draws natively.**
  - Anthropic's VS Code extension speaks the stream-json control protocol through the Agent SDK. It uses about
    60 `control_request` subtypes. A terminal is shown only behind `claudeCode.useTerminal`.
  - Codex's TUI and `exec` are themselves clients of `codex app-server`.
  - opencode's TUI and desktop app are both clients of its HTTP/SSE server.
  - The Desktop app's Code tab is "the same underlying engine with a graphical interface". Its docs list what
    it lacks.
- **Third-party ADEs that started in the terminal keep it as the default** and add chat as a second, optional
  surface:
  - Orca, where chat is an experimental toggle.
  - cmux, the closest analogue (Swift on libghostty), where chat is a sidecar.
  - Superset, which gained a CLI/CHAT toggle on 2026-10-02.
  - Sculptor, which has a terminal agent alongside a chat agent.
  - Collins, where the chat is experimental and has not been developed since the fork.
- **The chat-only wrappers are the cautionary tale.**
  - Crystal and opcode ran one process per turn with `--dangerously-skip-permissions`. Their issue lists are
    the parity gaps: no plan mode, no slash commands, edits without asking, mid-run input cancelling the task.
  - Crystal is deprecated.

## Three ways in, for Claude
1. **Raw control protocol** over `claude -p --input-format stream-json --output-format stream-json
   --permission-prompt-tool stdio`. Used by Collins (Python), Vibe Kanban (Rust), Sculptor and cmux. This is the
   path [[Native Session UI]] probed.
2. **The Agent SDK** (TypeScript or Python), pointed at the user's own `claude` with
   `pathToClaudeCodeExecutable`. Used by Orca, Superset and the VS Code extension. The SDK is a wrapper over
   path 1. It ships in lockstep with the CLI: the Python SDK pins `__cli_version__ = "2.1.287"`. The control
   protocol is documented only by the SDK source, so treat it as internal.
3. **ACP**, through `@agentclientprotocol/claude-agent-acp`, an ACP server built on the Agent SDK. Used by Zed,
   JetBrains, and Superset's chat toggle.
   - It needs Node and an npm package that releases about daily.
   - It is lowest-common-denominator. Live Bash output and subagent sessions need per-client `_meta`
     extensions. `AskUserQuestion` is disallowed outright unless the client supports form elicitation.
     `/clear`, `/cost`, `/login` and `/todos` are dropped.

There is no Swift SDK. An unofficial `ClaudeAgentSDK` Swift package exists and has not been looked at. Rust
ports exist. For Clinic, path 1 means the protocol lives in ClinicCore, with Foundation only.

## Other harnesses
| Harness | Headless transport | Stability | Vendor's own GUI uses it |
|---|---|---|---|
| Claude Code | stream-json control protocol | internal (SDK source) | yes (VS Code, Desktop) |
| Codex | `codex app-server`, JSON-RPC over stdio, typed schemas by `generate-ts` | "experimental", but its TUI is a client | yes |
| opencode | HTTP + SSE server, generated SDK; also `acp` | documented SDK | yes (TUI, desktop) |
| Gemini CLI | ACP (`--acp`) | ACP v1 stable | no (IDE bridge only) |
| Cursor CLI | ACP (`agent acp`), stream-json out | documented | — |
| Copilot CLI | ACP (`--acp`), public preview since 2026-01-28 | preview | — |
| Amp | `--stream-json[-input]`, "compatible with Claude Code's format" | undocumented | — |

ACP is the de facto standard for everything that is not Claude or Codex. Claude and Codex each have a richer
native protocol, and each has an ACP adapter (`claude-agent-acp`, `codex-acp`).

## How the multi-agent ADEs shape it
Orca has two tiers, and the others converge on the second.
- **`TuiAgentConfig`** covers 42 terminal agents with data only:
  - `detectCmd`, `launchCmd` and `expectedProcess`;
  - `promptInjectionMode` (argv, a flag, or stdin after start) and `draftPromptFlag`;
  - `preflightTrust`.
- **`StructuredAgentSessionAdapter`** has two implementations: Claude through the SDK, and Codex through
  app-server. It provides `acquire`, `dispatch`, `cancelTurn`, `answerPrompt(approval|question)` and `setOption`,
  with `compact`, `rewind` and `readCommands` optional. Both write one journal model, which the UI renders.

The others have the same shape:
- Superset's `HarnessAdapter` has `start`, `prompt`, `cancelTurn`, `respondToApproval`, `setMode` and `fork`.
- cmux's adapter has `send`, `stop`, `setOption`, `listCommands` and `forkSession`.
- Vibe Kanban's `StandardCodingAgentExecutor` normalises every agent into one entry type, streamed as JSON
  Patch.

ACP's update model is a ready-made vocabulary for that journal, even without speaking ACP:
- message and thought chunks;
- tool calls with `kind` (read, edit, execute, fetch…), `title`, `locations`, `status`, and content that is
  text, a diff `{path, oldText, newText}`, or a terminal;
- plans, available commands, modes and config options, and usage;
- permission options of the form allow/reject × once/always.

## What broke for the stream-json clients
- **Version pinning is universal.**
  - Vibe Kanban pins `@anthropic-ai/claude-code@2.1.119` "to avoid issues after updates".
  - Sculptor raised its floor to 2.1.258 for new models.
  - Orca uses the user's own CLI and excludes the SDK's bundled binary.
- **Recurring gaps:**
  - `AskUserQuestion` broke Vibe Kanban's UI when it appeared.
  - Plan approval's *clear context and approve* choice.
  - `/compact` and project slash commands. Sculptor notes that the stream-json mode skips the TUI's slash
    loader. `/context` did work in [[Native Session UI]]'s probe on 2.1.287, so that note may be stale.
  - Resume keyed on a `~/.claude/projects` path that a renamed worktree breaks.
  - Enterprise policy blocking bypass mode.
  - Superset found that ACP v2 reshaped `Diff` in a way that would have silently dropped diffs.
- **Workspace trust.**
  - Orca and Collins both write trust into Claude's config before a headless launch. Clinic cannot
    ([[ADR-018 Claude Data Write Policy]]).
  - Collins shows its own trust dialog first.
- **Interactive dialogs.**
  - Orca answers `onUserDialog` with `supportedDialogKinds: []`, refusing every CLI dialog it cannot draw.
  - cmux's transcript-backed chat leaves permissions to an *Answer in terminal* button.
- **Policy.** The SDK overview says Anthropic does not allow third parties to "offer claude.ai login or rate
  limits for their products, including agents built on the Claude Agent SDK". Clinic launches the user's own
  logged-in CLI, as Orca and Zed do, but how this applies needs settling before an ADR.

## What this suggests for Clinic
- **Keep the terminal as the default.** Make chat a second view of the same session, switched per tab and
  resumed by id. This is what Orca, cmux and Superset converged on, and it is shape 2 in [[Native Session UI]].
- **Speak the raw control protocol from ClinicCore**, as Collins and Vibe Kanban do. Do not take on Node for
  the SDK or the ACP adapter. Detect features from `initialize` and `system/init`. Refuse what cannot be drawn,
  as Orca does, and offer *Open in Terminal* for it.
- **Model the journal on ACP's update vocabulary**, so a later ACP or Codex adapter writes into the same model.
  The tiers would be:
  - terminal agents as data, Orca's `TuiAgentConfig`, which is nearly what [[ADR-004 Agent Scope]]'s adapter
    already implies;
  - structured adapters behind one protocol: Claude first, then Codex app-server or ACP.
- **The work is rendering, and the order matters:**
  1. permission cards with suggestions;
  2. `AskUserQuestion`, by moving the Grill pane in;
  3. plan approval;
  4. Edit and Write diffs, reusing the diff panel's text view ([[ADR-100 Diff Body Is A Text View]]);
  5. Bash output;
  6. subagents.

  The first two are already next in [[Log]].
