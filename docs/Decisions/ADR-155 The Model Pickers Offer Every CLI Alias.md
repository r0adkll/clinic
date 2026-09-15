---
status: accepted (built 2026-09-14)
date: 2026-09-14
supersedes: "[[ADR-064 Model and Effort Switching]] (the footer menu's list of aliases), and the alias lists named by [[ADR-071 New Session Screen]] and drawn by [[ADR-095 Automations]]"
tags: [adr, ui, sessions, models]
---
# ADR-155: The model pickers offer every CLI alias

## Context
User (2026-09-14): *"I've noticed that we don't surface the Fable models in our model pickers."*

Clinic never sends a model id of its own. Every picker sends an **alias** and lets the CLI resolve it
to the latest model of that family: the footer chip types `/model <alias>` ([[ADR-064 Model and Effort
Switching]]), the composer and Settings pass `--model <alias>` ([[ADR-071 New Session Screen]]), and an
automation's launch line carries it too ([[ADR-095 Automations]]). Those four lists were written by hand
in four files, all as *sonnet, opus, haiku* (the automation editor's in a different order), when the CLI
knew three aliases.

Claude Code 2.1.272 knows four. `claude --help` documents `--model` as taking *"an alias for the latest
model (e.g. 'fable', 'opus', or 'sonnet')"*, and its `/model` picker lists `fable` and `fable[1m]`
beside the others. A Fable session started from the CLI already shows correctly in Clinic — the footer's
`shortModel` reads `claude-fable-5-1` as *Fable 5.1* — but nothing in Clinic could start or switch to
one short of *Custom…* and typing the id.

## Options
- **Add "fable" to each of the four lists.** Fixes today's gap and leaves the next alias to be found
  the same way, one list at a time.
- **Query the Models API.** Rejected by ADR-064 already — it needs the OAuth token, and the pickers
  send aliases, not ids, so a catalogue of ids would answer a different question.
- **One list, read by every picker.** What the pickers actually share is *the aliases the CLI accepts
  by name*; give that a single home and let the pickers read it.

## Decision
- `ModelAlias.all` in the app target is the one list of aliases: **fable, opus, sonnet, haiku**, most
  capable first, which is also the order the CLI's own help uses. `ModelAlias.title` capitalises for
  display.
- The footer model menu, the composer's model picker (and its check of a model handed in from a task
  or a quick start, which decides between an alias and *Custom*), the Settings default-model picker,
  and the automation editor's model chip all read that list. *Default* and *Custom…* stay where each
  picker had them.
- An alias is still sent verbatim — `/model fable`, `--model fable` — so what *fable* resolves to is
  the CLI's business, as before. The `[1m]` variants are not offered: the footer's *Custom…* and the
  composer's *custom* field take them, and the CLI's own picker is the place to browse them.

## Consequences
- A new alias is one line in one file, and every picker gains it.
- Order changed from *sonnet, opus, haiku* to *fable, opus, sonnet, haiku* in every picker, so the
  menus read from most to least capable.
- Seen while here, not changed: the Settings *Default model* preference (`ClinicDefaultModel`) is
  written by its picker and read by nothing — the composer always opens on *Default* — so choosing a
  default there has no effect. That is its own decision.
