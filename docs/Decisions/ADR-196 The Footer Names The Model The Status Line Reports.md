---
status: accepted
date: 2026-10-10
supersedes: "the model source in [[ADR-064 Model and Effort Switching]] (the chip showing the alias sent until the transcript reports the resolved model)"
amends: "[[ADR-195 The Footer Shows The Effort The Status Line Reports]] (its model chip left unchanged)"
tags: [adr, ui, sessions, bug]
---
# ADR-196: The footer names the model the status line reports

## Context
[[ADR-195 The Footer Shows The Effort The Status Line Reports]] left the model chip alone. It read
`Tab.model`, which the launch's `--model` sets, then a pick from the chip, then the transcript once it names
a model. A session started on the CLI's default model therefore said *Model* until its first reply. A
`/model` typed into the terminal stayed wrong until the next transcript re-read. A pick from the chip showed
the alias sent, *Sonnet*, and not the model it resolved to. User, offered the fix: *"yes"*.

In 2.1.296 the status line input carries `model: { id, display_name }` from the session's runtime model,
and the CLI re-runs it when `mainLoopModel` changes. Clinic already stores it on the tab
([[ADR-157 The Status Line Reports Context]]), and the session card names its model from it.

## Decision
- The chip's label is the report's `display_name`, the name the CLI's own banner prints. Without a report
  it falls back to `Tab.model` shortened as before, then to *Model*.
- *Copy Model ID* and the *Custom…* field's starting text use the report's `id`, else `Tab.model`.
- `Tab.model` itself is unchanged. A child session still inherits it as its launch model
  ([[ADR-182 A Child Session Reports To Its Parent]]), so a model switched by a typed `/model` does not
  carry to a child yet.

## Consequences
- Built, and `make test` passes. Not seen on screen: Clinic Dev's window dropped out of both the window list
  and the accessibility tree before the chip could be read. The same report, on the same tab, gave the
  effort chip its *Medium* in ADR-195's run, and the CLI's banner there read *Sonnet 5.5*.
- Not exercised: switching from the chip. `/model` saves the pick as the user's default in
  `~/.claude/settings.json`, so it needs an isolated config directory.
