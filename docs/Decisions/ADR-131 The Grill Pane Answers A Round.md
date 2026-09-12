---
status: accepted (built 2026-09-12)
date: 2026-09-12
amends: "[[ADR-056 Session MCP Tools]] (one more tool), [[ADR-079 Panel Tabs]] (one more pane kind), [[ADR-055 No Prompt Composer]] (what a form is allowed to send)"
tags: [adr, ui, panel, mcp, grill, keyboard, milestone-4]
---
# ADR-131: The Grill pane answers a round

## Context
User (2026-09-12): *"When using the grilling or grill-me skills, which I love, the question / answer
format leaves a lot to be desired. It would be great if we could build in a panel or custom UI in
Clinic to interface with these rounds of questioning in a very enjoyable UX experience. I'm thinking
that rounds can be surfaced to the harness UI in a way where I can easily just accept the proposed
answer to a question, or enter an answer of my own, answer with multiple choice, navigate through them
with a keyboard, etc."*

The `grilling` skill is how this vault's ADRs get written: it works a design tree in **rounds**, asking
the whole frontier at once, each question numbered with the agent's recommended answer —

```
❓ **Q1** - **<question title>**: <body, possibly several paragraphs, possibly with choices>

➡️ <recommended answer>
```

— and then waits for every answer before recomputing the frontier. As terminal text that costs the
reader everything the structure was for: you scroll back to re-read Q3 while composing an answer to
Q1, you retype a recommendation you already agree with, choices sit buried in prose, and the agent has
to re-parse what you wrote to find out which question you meant.

The skill itself is not ours to change: it lives in the plugin cache under `~/.claude`, which is
read-only ([[ADR-018 Claude Data Write Policy]]). Whatever Clinic does has to work against the skill
exactly as it ships.

## Options
**Where the answers travel** was the decision everything else hung off.

- *A blocking tool* — the agent calls a tool that does not return until the user has answered, and the
  answers arrive as the tool result. Rejected, and not only for effort: [[ADR-056 Session MCP Tools]]
  answers `tools/call` on the main actor with a **15 s timeout**, one NDJSON request/response per
  connection, so a round that takes four minutes to answer needs a different transport. It is also the
  wrong shape. The session would sit **busy** on the state machine ([[ADR-026 Session State Machine]])
  for as long as the user thinks, with the spinner running; `⎋` would abort the round; and the
  questions would live inside a tool call with the answers inside its result, so the terminal — and
  the JSONL that [[ADR-059 Replay and Session Details]] replays — would hold no record of the
  interview at all.
- *A posting tool, answers as the user's next message* — chosen. Below.
- *Parsing the transcript only* — no tool; derive every round from the `❓`/`➡️` pattern. Needs zero
  cooperation from the model, but it cannot recover a real choice list from prose, has no explicit
  round boundary, and breaks the day the skill rewords its format. Kept as the **fallback**, not the
  only path.

## Decision

### `ask_round` posts; the answers arrive as the user's next message
One new tool joins [[ADR-056 Session MCP Tools]]' set, `ask_round(topic, roundIndex, questions[])`,
default on, with its own switch under Session tools. It stores the round on the session, opens the
Grill pane, raises attention as `.needsInput` (the path `notify_user` already takes), and **returns
immediately** — its result tells the agent the round is posted and to end its turn, because the
user's answers will arrive as their next message.

The agent's turn then ends, which is what the skill was going to do anyway ("wait for the user's
answers before the next round"). Claude Code sits at its prompt. When the reader hits Send, Clinic
composes one Markdown block and `sendPaste`s it into the agent surface with Return — the path
[[ADR-055 No Prompt Composer]] deliberately kept for exactly this, and the one `RunStore` and the PR
page's *send to session* already use. **Nothing about the transport changes**: no long-lived socket, no
timeout to lift, no new state for a session to be in.

The agent also still *prints* the round as prose, because the skill makes it. That is not waste, it is
the record: the terminal scrollback and the JSONL stay complete, replay still works, and with the pane
closed or the tool switched off a round is exactly as usable as it is today. **The pane is the
interface; the terminal is the record.**

### A pane, not a sheet
`PanelPane.Kind.grill` in the right-hand panel ([[ADR-079 Panel Tabs]]) — flame glyph, `minWidth` 460,
`⌘⇧K` for its opener, joining the Panel menu and the shortcut editor's Panel section
([[ADR-073 Rebindable Shortcuts]]). A modal sheet was the obvious alternative and is wrong: a grill
round is precisely the moment you want to read the diff, open a file or check a PR before committing to
an answer, and a sheet forbids all three. A long round does not need a new focus mode either —
`zoomPanel` (⌘⌥⇧J) already exists.

Chrome follows the panel's own conventions: `PaneChrome` header carrying the round, its topic and
*4 of 6 answered*; a footer in the PR panel's idiom ([[ADR-129 A Merge In Flight Says So]]) with
**Accept all recommendations** beside an accent **Send 6 answers**.

### Each question is title, body, recommendation and — when the agent offers them — choices
The schema is deliberately small enough that the model fills it reliably: per question an id, a title,
a markdown body, an optional recommendation, and an optional list of choices, each with a label, an
optional detail and a `recommended` flag, plus `allowsMultiple` for multi-select. An answer is
therefore one of: the recommendation accepted, one or more choices picked, free text, or skipped.

The skill's **design tree** is not in the schema. Drawing the tree and which branch each question hangs
off is a second view to design and a field the model has to get right before it is worth anything; if
the pane earns it, that is a later ADR.

Recommended choices get the accent treatment and nothing else does — an accent glyph on an accent
wash, never a colour per choice.

### Two keyboard modes, because this pane has to accept typing
[[ADR-107 The Images Pane Has A Finder Keyboard]] settled the hard parts by measurement:
`.onKeyPress` **never delivers a command chord** (SwiftUI routes them through menu key equivalents),
a bare key cannot be a window-wide equivalent with the terminal one keystroke away, and a pane must
not take focus when a tool opens it. This pane adds a constraint the images pane did not have — the
reader types prose into it — so one flat keymap cannot work. Two modes, as Finder has list and rename:

| Key | Navigate | Answering |
|---|---|---|
| `j` `k` / `↑` `↓` | walk the questions | — |
| `⏎` | **accept the recommendation** | newline |
| `1`–`9` | pick that choice | — |
| `e` | start typing your own | — |
| `⇥` / `⇧⇥` | next / previous question | commit, then next / previous |
| `s` | skip — *you decide* | — |
| `Space` | expand or collapse the body | — |
| `⎋` | — | back to Navigate, draft kept |
| `⌘⏎` | Send the round | Send the round |
| `⌘C` | copy the round as Markdown | — |

The bare keys live in one `NSView`'s `keyDown`, the pane's single responder, with the text editors
inside it; `⌘⏎` and `⌘C` are **menu key equivalents**, enabled only while a Grill pane is in front,
because ADR-107 proved nothing else receives them. `panelHoldsKeyboard` already stops the agent
surface reclaiming focus when a re-render fires.

**Accept all recommendations** is the interaction that makes the rest worth building: in a round of six
you usually agree with five, so one key fills those and you spend your attention on the one you don't.

### The pane never takes the keyboard when a round arrives
ADR-107's rule holds without exception: `ask_round` can land while the reader is mid-sentence to the
agent, and a pane that grabbed focus would eat the rest of that sentence. The pane takes the keyboard
when the reader opens it — its chip, `⌘⇧K`, or clicking its notification — and never because a round
arrived. A rule that sometimes moves focus and sometimes doesn't, keyed on whether the prompt looked
idle, was considered and rejected: it is invisible, so it would be indistinguishable from a bug.

### What Send writes
One block, each answer naming its question, with an accepted recommendation **echoed** rather than
merely acknowledged — so the agent cannot mis-resolve which recommendation "yes" referred to:

```
Answers to round 3 — Grill panel design:

Q1 (Round transport) — accepted your recommendation: an MCP tool that posts the round
and returns, with the answers arriving as the user's next message.
Q2 (Where it lives) — B: a pane in the right-hand panel.
Q3 (Keyboard) — mine: two modes, but ⇥ should commit and advance, not just advance.
Q4 — skipped, you decide.
```

Unanswered questions send as skipped rather than blocking Send; a round the reader wants to answer
half of is a round they get to send.

### Only the newest round is open
A round has four outcomes, not three. **Open**, **sent**, **answered elsewhere** — and **superseded**,
for the agent posting another round without waiting for this one. Building it showed why: the footer
acts on *one* round, so two open rounds give it two Sends with no way to say which round either meant.
`ClinicState.postGrillRound` closes any open round as it appends, which puts the invariant beside the
state it protects and makes it checkable without a window.

### Rounds persist, and a round answered in the terminal says so
Rounds and their answers are stored per session in `ClinicState`, the way `show_image`'s attachments
already are ([[ADR-021 Persistence]]) — so prior rounds collapse above the current one and stay
readable ("what did I decide about the transport?"), and the pane survives a relaunch even though
[[ADR-079 Panel Tabs]] persists no panes. That transcript is also the raw material for the ADR the
round exists to produce, which is what `⌘C` is for.

If the reader answers in the terminal instead and the session goes busy with nothing sent, the round is
marked **answered elsewhere** and dimmed. The pane never shows a question as open when it isn't.

### A transcript parser is the safety net, not the path
The feature would be worthless the first time the model printed a round and skipped the tool, so the
`Stop` hook ([[ADR-027 Installed Hook Set]]) — the end of a turn, already an event Clinic acts on
([[ADR-127 The PR Panel Refreshes On Events Not On A Timer]]) — checks whether a round arrived during
the turn, and if none did, scans that turn's assistant text for `❓ **Qn**` / `➡️`. `TranscriptTurns`
already yields `.assistant(text, date)` for replay and the diff panel's turn snapshots, so the parser
reads what is there rather than introducing a second reader.

A parsed round is **freeform only** — title, body, recommendation, no structured choices, since prose
choices cannot be recovered reliably — and it is offered rather than imposed: the pane's chip appears
with *3 questions detected*. Parsing runs once per turn end, only when the pattern is present.

### The skills are not modified, and the channel that reaches them already ships
The `grilling` skill governs **content and process** — build a design tree, ask the whole frontier in
one round, number each question, give a recommendation, find facts yourself, wait for every answer
before recomputing the frontier, do not act until the user confirms. It says nothing about *where* a
round is displayed or *how* the answers come back. Clinic governs exactly that and nothing else, so
**the two sets of instructions are orthogonal and there is nothing to override.** No fork, no
replacement, no edit under `~/.claude`.

Three layers carry the nudge, none of them the skill:

1. **The tool description** in `MCPToolSpec.all`, which names the trigger ("when you are about to ask
   the user a round of numbered questions each carrying a recommended answer, as the `grilling` /
   `grill-me` skills do") and pre-empts the two ways the model can get it wrong: *one call per round
   with every frontier question in it*, not one per question, and *write the round out in the
   conversation as well*, because the tool is an addition to the transcript and not a replacement for
   it.
2. **The MCP server's `instructions`**, which is the layer that does the work, because it lands in the
   session's system prompt rather than in a tool list the model may skim. This needs no new mechanism:
   `clinic-hook`'s `initialize` response (`Sources/clinic-hook/main.swift:110`) already carries an
   `instructions` string, and that string already gives *behavioural* direction — "Use notify_user when
   you need the user's attention and set_session_title once you know what the session is about."
   **Verified, not assumed**: a session hosted by Clinic was asked what it could see, and its context
   held that sentence byte-identical under `# MCP Server Instructions / ## clinic`. One sentence about
   `ask_round` joins it.
3. **The `Stop`-hook parser** below, for the turn where neither nudge fired.

Layer 2 costs one small change. The shim answers `initialize` **locally, from a hardcoded string**,
but ADR-056 does not list a tool the user has switched off — so instructions naming a disabled
`ask_round` would be a lie. The shim therefore asks Clinic for its instructions at `initialize`, one
more NDJSON round trip on the path it already uses for `tools/list`, and falls back to the static
string when the app does not answer, because the shim must always exit cleanly.

Discoverability gets one more thread: a **Grill…** action types `/grill-me <topic>` into an idle
session through `TabStore.sendSlashCommand` ([[ADR-064 Model and Effort Switching]]'s path).

### Two ways of hooking in that were rejected
- **Ship a Clinic-flavoured `grill` skill.** [[ADR-084 Plugin Marketplace]]'s amendment makes this
  *legal* — Clinic writes nothing under `~/.claude`, but hands the `claude` CLI user-initiated argv
  shown in full — so a `clinic-skills` marketplace plugin would install through the Marketplace screen
  that already exists. Rejected because it forks a skill the user likes: upstream releases would have
  to be tracked forever, and `/grill-me` is muscle memory that would keep pointing at the unadapted
  one. It stays the escape hatch if layers 1–2 measure badly.
- **A `UserPromptSubmit` hook that injects context when the prompt is `/grill-me`.** It cannot work as
  installed: [[ADR-015 Hook Transport]] chose `async: true` precisely so the helper "never delays the
  CLI", and an async hook's stdout is never awaited, so it can inject nothing. Making that one event
  synchronous would put a socket round trip on the critical path of **every prompt the user submits**,
  to buy a nudge on the rare prompt that starts a grill.
- **`--append-system-prompt`** in [[ADR-016 Launch Shape]] would work, but layer 2 occupies the same
  niche strictly better: identical effect, already shipping, and no change to the launch shape. It is
  not the escalation on record; the skill fork is.

### Vocabulary
[[ADR-025 Vocabulary]] gains: a **Grill** (the interview), a **Round**, a **Question**, its
**Recommendation**, its **Choices**, and an **Answer**. The pane is *Grill*; the tool is `ask_round`,
named for what it does so any interviewing skill can drive it.

## Consequences
- The pane is the first thing in Clinic that composes text *for* the agent surface rather than relaying
  text *to* it. That is within what ADR-055 left standing — it is a form with one structured job, not
  the general prompt editor that ADR was about — but it is the edge, and the next thing that wants to
  send prose should argue for itself rather than cite this.
- `ask_round` is the first tool whose result instructs the agent about its own turn. If the model
  ignores that and keeps talking, the round still stands and the answers still land; the turn is just
  untidy.
- A round posted to a session the reader never returns to stays open forever. It shows in the home
  screen's what-needs-you ([[ADR-120 The Empty Screen Is A Home]]) with the count, which is the only
  place it needs to nag from.
- Two modes means a mode indicator: the pane has to say which keyboard it is in, or `⏎` becomes a
  coin toss.
- The answer composer is a pure function over a round and its answers, so it is unit-testable without
  a surface ([[ADR-022 Testing and CI]]) — as is the parser, against captured `grilling` output.
- Milestone 4 gains the pane; the design tree view, mid-turn single questions, and reordering a round
  are all explicitly out.

## Corrections
Three things this work walked into, two of them only visible once it ran:

1. **`⌘C` is not available to this pane.** ADR-107 gave the Images pane Edit ▸ Copy by implementing
   `copy(_:)` on the `NSView` that holds its keyboard. This pane's Navigate keyboard is a SwiftUI
   `.focusable()` container, which has no such hook, and a Panel menu item claiming `⌘C` would shadow
   copying in the terminal window-wide. Copying a round is **⌘⌃C** and a header button instead — the
   table above says `⌘C` because that is what the pane *would* have taken; it does not.
2. **Clicking a question did not hand the pane its keyboard.** Measured in a smoke instance: the click
   moved the highlight, and the next `j` typed a `j` into the agent's prompt. This is exactly ADR-107's
   `focusViewer()` trap in a new place — a pane with two ways in needs both of them to carry the
   keyboard, so the card's tap sets the focus state as well as the selection.
3. **Nested `ForEach`es put the wrong round on screen.** Question ids are unique only *within* a round —
   every round has a `Q1` — so a `ForEach` of rounds each holding a `ForEach` of questions collided
   inside the `LazyVStack`, and posting round 4 left the pane showing round 3's questions under round
   4's header. The pane builds one flat list with composite `<round>#<question>` ids.

## Verification
Built and smoke-tested 2026-09-12 in an isolated instance (its own `CLINIC_APP_SUPPORT`; `~/.claude`
read as usual, never written).

- **Layer 2 end to end through the real shim binary**: `clinic-hook mcp` against the live socket
  returned the instructions with the `ask_round` sentence in them, built from the enabled tools rather
  than a constant. `tools/list` offers `ask_round`; `tools/call` posts a round and answers with the
  end-your-turn text; a round with no answerable question comes back as an error the agent can act on.
- **The keyboard**: `j j` walked Q1 → Q3 with the terminal untouched; `1` and `3` picked two choices on
  a multi-select; **Accept all recommendations** filled the other four and left the reader's own answer
  alone, taking the header to *5 of 6* and disabling itself.
- **Send** pasted the composed block into the surface verbatim and folded the round to *sent*, footer
  gone. Checked against a shell, never against a live agent turn.
- **Supersede** checked in the persisted state: posting a second round left the first `superseded` and
  exactly one round open, with choices, recommended flags and `allowsMultiple` all surviving the
  round trip.

450 ClinicCore tests pass (32 of them this feature's) and `make build` is clean. Smoke instance and its
App Support removed; `com.r0adkll.clinic` gained no keys.
