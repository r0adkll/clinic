---
status: accepted (built 2026-09-16; the card's wording superseded by ADR-158)
date: 2026-09-16
supersedes: "the context-size half of [[ADR-156 Sessions Can Be Cards]] (a token count, because nothing stated the window)"
amends: "[[ADR-027 Installed Hook Set]] (the settings file also registers `statusLine`)"
tags: [adr, hooks, sidebar, sessions]
---
# ADR-157: The status line reports context

## Context
[[ADR-156 Sessions Can Be Cards]] showed a card's context as a token count ("85k context"). The reason
given: the window size differs by model and alias and nothing in the transcript states it. User
(2026-09-16): *"Can the claude code session not report its context %? Is there no way to get that
information?"*

It can, and the transcript was the wrong place to look. Claude Code pipes a JSON document to the
`statusLine` command. The format is documented inside the 2.1.273 binary and includes
`context_window { total_input_tokens, context_window_size, current_usage, used_percentage,
remaining_percentage }` (pre-calculated, `null` before the first message), `model { id, display_name }`,
`effort { level }` (live, when the model supports it) and `rate_limits`. It re-runs on changes to
`tokenUsage`, `permissionMode`, `vimMode`, `mainLoopModel`, `fastMode`, `effortValue`,
`thinkingEnabled` and `prStatus`, plus `refreshInterval` seconds if set. As far as the binary shows, no
hook payload carries these fields.

`statusLine` is a single setting, and the `--settings` file Clinic passes outranks the user's. On this
Mac `~/.claude/settings.json` already sets one: Orca's `claude-statusline.sh`, which forwards the same
input to Orca. User: *"its okay to clobber the Orca statusline.sh file as we are wanting to replicate
their behavior in our app."*

## Options
- **Chain the user's status line**: forward the input, then run the effective `statusLine` from the
  user/project/local settings and print its output. Rejected on the user's word. Clinic is taking
  over what Orca's line did, and chaining means re-implementing the CLI's settings precedence in a helper
  that runs on every token update.
- **Forward and print nothing.** Chosen.

## Decision
- **`HookSettings.json` registers `statusLine`** alongside the hooks, in every settings file Clinic writes
  (plain and worktree variants): `{"type": "command", "command": "<clinic-hook> statusline <hook.sock>",
  "padding": 0}`. No `refreshInterval`: the CLI's own triggers cover every number shown.
- **`clinic-hook statusline <socket>`** reads the input, stamps `"hook_event_name": "StatusLine"` so it can
  share the hook socket and decoder, sends it, and **prints nothing**. A Clinic session has no status line
  under its prompt. When Clinic is not running, the connect fails at once and the helper exits 0.
- **`StatusLineReport` (ClinicCore)** is decoded from the top level of a `StatusLine` event into
  `HookEvent.statusLine`: used percentage, window size, input tokens, model id and display name, effort
  level. Every field is optional.
- **`TabStore` stores it on the tab and stops there.** It changes no state, never nudges the transcript
  follower (it fires many times a turn), and `HookService` leaves it out of the debug trace.
- **The card's "where and how" line prefers the report**: *Opus 5 · xhigh · 42% context*. The percentage
  is rounded down, so a nearly full window never reads 100% early. The effort comes from the report
  because `/effort` changes it without a hook. The transcript's token count and model remain the fallback
  for a session with no report: an attached one (`claude attach` takes no `--settings`), or one whose
  first status line has not arrived.

## Consequences
- Verified against the real CLI: `claude --model haiku --settings <file>` in a pty in this repo, with the
  built helper pointed at a throwaway listening socket. Three payloads arrived, stamped `StatusLine` with
  the right `session_id`. The first had `used_percentage: null`, `context_window_size: 200000`; after a
  one-word reply, `used_percentage: 16`, `total_input_tokens: 31577`. The terminal showed no status line.
  That run left one short transcript under the clinic project in `~/.claude/projects` (interactive mode
  cannot skip persistence), hidden from the sidebar as a discovered session.
- Not verified in the app UI with a live session; the card's use of the report is covered by the build and
  the decoding test, not by a screenshot.
- Anyone relying on their own status line inside Clinic sessions loses it. Outside Clinic it is unchanged.
- `rate_limits` arrives too and is not read yet. It overlaps [[ADR-051 Usage Panel]], which polls for the
  same numbers.
