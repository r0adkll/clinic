---
status: accepted
date: 2026-09-29
amends: "[[ADR-122 Projects Have Run Configurations]] (the editor sheet's list controls)"
tags: [adr, ui, runs]
---
# ADR-175: A run configuration can be duplicated

## Context
User (2026-09-29): *"In the run configuration editor we should be able to duplicate a selected
configuration"*

[[ADR-122 Projects Have Run Configurations]] gave the editor sheet `+`/`−` under its list. Making a
variant of a configuration (another flavour, another device, one more env var) meant adding a blank one
and retyping the command, directory and environment.

## Decision
- **Duplicate** sits after `−` under the list (`plus.square.on.square`, ⌘D), acting on the selection,
  and in each row's context menu beside *Delete*.
- The copy is inserted right after the original and selected. It is named *‹name› Copy* and has every
  field of the original: icon, command, directory, env, re-run, device, a compound's members, and the
  keys Clinic does not know.
- It is a new configuration in the editor's terms, so *Save* gives it an id made from its name, never
  the original's.

## Consequences
- Nothing changes in `run.json`'s format; a duplicate is only another configuration once saved.
- Verified: `make build` succeeds. Not run: the sheet in a smoke instance.
