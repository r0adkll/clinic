---
status: accepted (built 2026-10-15)
date: 2026-10-15
amends: "[[ADR-216 The Footer Returns Under Both Areas]] (the footer's height and its context gauge), [[ADR-157 The Status Line Reports Context]] (more of the payload is read)"
tags: [adr, ui, footer, context, status-line]
---
# ADR-217: The context meter explains itself

## Context
After [[ADR-216 The Footer Returns Under Both Areas]], user (2026-10-15): *"The bottom bar is now shorter than
before (due to the lack of buttons) so we should give it some more height. Next the context indicator we should
beef up a bit and maybe give it a hover tooltip to show information about the sessions context (I'm not sure if
claude can give us the composition of the context, but happy to iterate on this idea)"*.

What the CLI sends to a `statusLine` command (read from CLI 2.1.301's bundle):
- **`context_window`**: `used_percentage`, `remaining_percentage`, `context_window_size`, `total_input_tokens`
  (input + cache write + cache read of the last request, which is the context's size), `total_output_tokens`, and
  `current_usage` — the last request's `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`
  and `output_tokens`.
- **`cost`**: `total_cost_usd`, `total_duration_ms`, `total_api_duration_ms`, `total_lines_added`,
  `total_lines_removed`.
- **Not sent:** what fills the context — system prompt, tools, MCP servers, memory files, messages. Only `/context`
  shows that, in the terminal.

`clinic-hook statusline` already forwards the whole payload, so nothing new crosses the socket.

## Decision
- **The footer is 32 pt tall**, the height it had when it held the openers' chips.
- **`ContextMeter`** at its trailing end: a 64 × 6 bar, the percentage and *used / window* in tokens (*44.6k / 1M*).
  The bar is secondary until 90 %, then orange, where Clinic also voices the limit ([[ADR-203 Limits, Long Turns And
  peon-ping]]).
- **Hovering it for 350 ms, or clicking it, opens a card:** the percentage over a wide bar, *used of window ·
  left*; *Last request*: read from cache, written to cache, new input, reply; *This session*: cost, time and API
  time, lines added and removed. A line at the foot says what fills the context isn't reported, and to type
  `/context` in the session to see it.
- **`StatusLineReport`** gains `lastRequest` (`RequestTokens`) and `cost` (`SessionCost`), decoded and encoded for
  the trace, with tests.

## Consequences
- The composition by source stays out of reach. If it is wanted later, the ways in are typing `/context` into an idle
  session and reading the screen, or estimating from the transcript. Both are fragile, and both were left for
  another round.
- Cost is the CLI's estimate. On a subscription it is not a bill.
