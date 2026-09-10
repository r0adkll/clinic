---
status: accepted
date: 2026-09-10
supersedes: ADR-012
tags: [adr, process, docs]
---
# ADR-105: The vault lives in the repo

## Context
[[ADR-012 Process]] put the vault at `~/SoftwareProjects/vaults/clinic`, outside the repo, mirroring
the Ditto setup. 104 ADRs, the design tree, the architecture notes and a 1500-line log now live there
with no history: nothing records when a decision was written versus when it was amended, a mistaken
edit is unrecoverable, and the design that explains a commit is not reachable from that commit. The
repo is public ([[ADR-011 Repo Naming and License]]), so the reasoning may as well be too.

User (2026-09-10): *"We've been tracking the documentation of this project in our obsidian vault.
Let's move this vault into the project so we can track it with source control."*

## Options
- **Vault at the repo root.** Shortest paths, but `.obsidian/` and eight docs folders sit next to
  `Sources/` and `Packages/`, and the vault indexes the whole tree.
- **Vault under `Design/`.** Matches the `Design/Design Tree.md` phrasing already in `CLAUDE.md`, but
  nests Decisions, Research and Memory under a folder named for one of them.
- **Vault under `docs/`.** One conventional folder, docs and code visibly separate, vault root is
  unambiguous.

## Decision
The vault moves to `docs/` in the repo and is tracked with the source. `docs/` is the Obsidian vault
root, so its internal layout is unchanged: `00 Home.md`, `Backlog.md`, `Architecture/`, `Decisions/`,
`Design/`, `Memory/`, `Research/`. Every path in this ADR set that read
`~/SoftwareProjects/vaults/clinic/X` now reads `docs/X`.

`docs/.obsidian/` is gitignored. It is per-machine editor state — `workspace.json` alone changes on
every pane you open — and the vault needs no configuration to be read.

The Ditto process from [[ADR-012 Process]] otherwise stands: grilling rounds → ADRs → Design Tree →
dated Log entries → Backlog → milestone-based delivery.

## Consequences
- `~/SoftwareProjects/vaults/clinic` is gone; re-open the vault in Obsidian at `clinic/docs`.
- A commit can carry its ADR and its Log entry, and `git log` over `docs/Decisions/` is a history of
  the design.
- Documentation edits show up in the repo's diff, so a change that lands without its ADR is now
  visible rather than silent.
