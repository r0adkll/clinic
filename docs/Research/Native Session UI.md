---
tags: [research, architecture, claude, transcripts]
date: 2026-10-02
sources: [claude --help (CLI 2.1.287), probes run against CLI 2.1.287]
---
# A native session UI instead of the embedded terminal

User (2026-10-02): *"explore … moving the transcript and prompting into a full Clinic UI vs embedding the
terminal to wrap Claude Code CLI. Let's explore the feasibility."* This is an exploration, not a decision. It
reopens [[ADR-003 Claude Code Integration Model]] option 2 and [[ADR-055 No Prompt Composer]].

## The transport exists and works
`claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
--permission-prompt-tool stdio` is the protocol the Agent SDK speaks to the CLI. There is no Swift SDK. Clinic
would speak the protocol itself over the child's stdin/stdout. That is newline-delimited JSON, so it does not
need the SDK.

Measured against 2.1.287 with a Python driver (haiku, scratch directory):

| Need | What the CLI does |
|---|---|
| Handshake | `control_request` `initialize` returns the slash commands and skills, with descriptions and argument hints. That is enough to build a native `/` menu. |
| Streaming text | `stream_event` records carry the API deltas. Full `assistant` and `user` records follow each message. |
| Permission | A `can_use_tool` control request carries `tool_name`, `input`, `description` and `permission_suggestions` (the "always allow" rules and their destination). The tool runs once the host answers `allow` with `updatedInput`. |
| Permission, no handler | Without `--permission-prompt-tool stdio`, `--permission-prompts host` alone denied the tool at once as `user-rejected`. The flag is required. |
| `AskUserQuestion` | Arrives as `can_use_tool` with `requires_user_interaction: true`. Answering with `updatedInput.answers` (question to label) worked: the model reported the chosen answer. |
| Interrupt | `control_request` `interrupt` killed a running `sleep 20`. The turn ended with `result` `error_during_execution`, `terminal_reason: aborted_tools`. |
| Model switch | `control_request` `set_model` takes effect on the next turn. `/context` then reported the new model. |
| Slash commands | `/context` sent as a user message returned its report as markdown text. |
| Queued prompts | A second user message sent while a turn ran was held and run as its own turn afterwards. |
| Turn end | A `result` record carries the turn's cost, usage, `modelUsage` and context window, and `permission_denials`. |
| Hooks | Settings hooks still run. `--include-hook-events` puts their lifecycle on the stream. |
| Transcript | The session is written to `~/.claude/projects/…/<id>.jsonl` as usual, with `entrypoint: sdk-cli`. Clinic's readers and the TUI's `--resume` see the same file. |

## What it replaces in Clinic
From a survey of the code (2026-10-02):

- **State.** The state witnesses could all come from one source. Today state comes from hooks or the mod, OSC
  9;4 and the title glyph, the transcript follower, and process exit ([[ADR-166 Session State Has More Than One Witness]]).
  In stream-json mode, busy, turn end, permission wait, interrupt and exit are all explicit records on a pipe
  Clinic owns.
- **Writes to the PTY.** These become JSON messages: `sendSlashCommand` gated on `isAtPrompt`, `/model` and
  `/effort`, Ctrl-C twice for Stop, `/bg`, and `sendPastedLine` from the Grill pane, Run's *Fix with Claude* and
  the PR page. There is no prompt gate, because input queues.
- **Grill and permission work.** The next steps in [[Log]] were "mirror `AskUserQuestion` into the Grill pane,
  then permission approvals from Clinic". In this mode they are no longer mirrors: they are the only UI those
  requests have.

## What it costs
- **Everything the TUI draws, Clinic must draw.** That includes:
  - markdown and code rendering, and diffs for Edit and Write;
  - tool rows and subagent nesting (`--forward-subagent-text`);
  - the todo list and thinking;
  - the permission dialog and its "always allow" choices;
  - plan-mode approval, `AskUserQuestion`, and image paste and attachments;
  - `@`-file completion, `!` shell mode, history, and the status line.

  [[ADR-059 Replay and Session Details]]'s `TranscriptTurns` is too flat for this. It flattens text and drops
  thinking and tool input, and it reads the whole file. A new incremental model would be needed, built from
  stream records. `TranscriptFollower`'s offset-tailing shows the shape.
- **Interactive-only commands disappear or need native screens.** These include `/config`, `/login`,
  `/resume`'s picker, `/agents`, `/plugin`, `/mcp`, `/permissions` and `/memory`. Most of these Clinic already
  has as screens. The rest would be "open in terminal".
- **Feature parity is a moving target.** The CLI ships weekly. Every new TUI affordance is missing in Clinic
  until it is built. A mod's panes, bands and toasts render in the TUI and have no stream-json equivalent; this
  is unverified.
- **The tab model assumes a surface.** `Tab.surface` is non-optional, and about 21 call sites use it. Replay
  tabs fake a surface running `/usr/bin/true`. A surface-less session tab means making `surface` optional, or a
  `.native(SessionID)` kind with its own content view.
- **`read_terminal` and the user's terminal habits** (Ghostty keybinds, vim mode, selection) no longer apply to
  sessions. Shell tabs keep the terminal.
- **Trust prompt.** `-p` skips the workspace trust dialog. Clinic would need its own trust gate to keep
  [[ADR-068 Chats]]'s assumption honest.
- **Auth and billing.** In the probe, a subscription login worked in `-p`. `fast_mode_disabled_reason:
  sdk_opt_in_required` shows that some features gate on the SDK entrypoint.

## Shapes, cheapest first
1. **Live native transcript beside the terminal.** A read-only rich view that tails the JSONL. The terminal
   stays the input and the source of truth. This is low risk: it extends Replay, and it touches no launch or
   state code.
2. **Two modes per session, one transcript.** A session runs either in a terminal (as today) or native
   (stream-json), and can be reopened in the other with `--resume <id>`. This works because both write the same
   JSONL. It lets the native UI start small (chats first, [[ADR-068 Chats]]), with *Open in Terminal* as the
   escape hatch for anything it can't draw yet.
3. **Native only.** The terminal is dropped for sessions. This is not advisable while the CLI's interactive
   surface is growing faster than Clinic could follow.

The probe that would decide between 2 and 3: run a mod (`clinic-session` or a pane mod) under `-p
stream-json` and see what reaches the stream.

How other ADEs answer the same question is in [[ADE Session UIs]]. The vendors' own GUIs are all headless and
native. Third-party ADEs that started in a terminal keep it as the default and add chat beside it. Every
headless client pins its CLI version.

## A fourth shape: the terminal stays, the panel answers
User (2026-10-02): *"should we instead treat a native rendered UI more as a high-level transcript log … keep
the terminal as the main view but keep high-level, user interaction, and other prompts rendered in a special
panel that can inline these actions with the top-level prompts such as permissions, questions, etc"*.

The question is whether Clinic can answer a prompt while the CLI runs interactively. This was measured with a
probe mod under a PTY on 2.1.287:
- **A mod cannot answer the terminal's permission dialog.** The type declarations say: "The permission dialog
  is drawn by the engine alone, since its answer authorises an action; a plugin adds context with
  `$.ui.notice`."
- **A mod can answer before the dialog appears.** It does so through `classic.PermissionRequest`, returning
  `{ decision: { behavior: 'allow' | 'deny', updatedInput?, updatedPermissions? } }`.
  - A hook that held for 8 s and then allowed: the terminal never drew its dialog and showed `Waiting… (running
    PreToolUse hook · 3s)` meanwhile. The command ran.
  - A hook that held for 4 s and then returned `next(e)`: the terminal's own "Do you want to proceed?" dialog
    appeared at once.
  - So the panel and the terminal do not race. While the mod holds a request, Clinic owns the answer. Handing
    the request back gives it to the terminal.
- **Questions.** `tool.call` can answer `AskUserQuestion` itself (`{ result }`), by the same hold. Untested.
- **Prompts.** `$.prompt.submit({ text, asUser: true })` submits a prompt from inside the CLI. It could replace
  `sendPastedLine` for the Grill pane and *Fix with Claude*. Untested, including mid-turn behaviour.
- **Gotcha.** A mod that passes `$` to anything but a function declared at the top of its file does not load.

The shape this allows:
- **An interaction log in a panel pane** ([[ADR-079 Panel Tabs]]). It shows the session's top level:
  - each user prompt;
  - one line per turn (its last words or recap, duration, outcome, and its changes linked to the Diff panel's
    turn);
  - inline cards for what needs the user: permissions with their "always allow" suggestions, questions (the
    Grill pane moved in), plan approval, notifications.

  History comes from the transcript follower that already exists. Live cards come from the mod.
- **The answer path.** The mod's `PermissionRequest` hook posts the request and waits for Clinic's reply on
  the same socket. The socket answers `204` today, so it would need to return a body. The hook returns
  Clinic's decision. On a timeout, when Clinic is gone, or when the user picks *Answer in terminal*, it
  returns `next(e)`, and the terminal dialog appears as it does today.
- **Answering in both places** is possible in principle, but unverified. While holding, the mod could open its
  own pane in the terminal with the same buttons and settle with whichever answer comes first.
- **No re-rendering of tool output.** The terminal keeps drawing the work. The panel draws only a small, closed
  set of card types. This is far cheaper than shapes 2 and 3, and it does not reopen [[ADR-055 No Prompt Composer]].
- **Risks.**
  - A held hook stalls the session if Clinic never answers, so the timeout is not optional.
  - "Always allow" writes rules through the CLI to the destination it names, as the terminal dialog does.
  - On CLIs without mods, the settings-hook fallback ([[ADR-015 Hook Transport]]) is asynchronous. There, the
    panel can only show the request and point at the terminal.
