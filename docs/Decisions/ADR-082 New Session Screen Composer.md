---
status: accepted
date: 2026-09-08
supersedes: the layout half of ADR-071
tags: [adr, ui, sessions]
---
# ADR-082: New session screen as a composer card

## Context
[[ADR-071 New Session Screen]] settled *what* the screen does; it left the layout as a stack of loose
parts — a centred hero with the project icon at 48pt, a bare prompt box, then model / effort / worktree
floating in a toolbar row underneath, disconnected from the box they configure. The screen also said
nothing about the project you were about to work in.

User (2026-09-08) reported the placeholder not lining up with typed text, and asked what else the screen
could do visually.

## Decision
- **The placeholder lives inside the editor's padding.** It was overlaid on the padded frame (14pt) while
  the text sat at the editor's own inset (8pt + 5pt), so it rendered 6pt low. The overlay now sits on the
  `TextEditor` before `.padding`, offset only by the 5pt `NSTextContainer` line-fragment padding that
  SwiftUI does not expose. Verified by screenshotting the placeholder and the same string typed: identical
  first-ink pixel.
- **One composer card.** Model, effort and worktree are chips in a bar *inside* the prompt box, with a
  circular send button at its trailing edge. The card takes an accent focus ring. `Empty Session` stays in
  the footer as the secondary path.
- **Compact header with project context.** Icon at 40pt beside the name, path in a monospaced caption, and
  the repository's current branch as a pill. Replaces the centred hero.
- **A wash of the project's colour** behind the card, taken from the *average colour of the project icon*
  (`ProjectIconCache.tint(for:)`), falling back to ADR-050's hashed monogram colour. Each project's start
  screen looks like its own icon.
- **Effort reads as the ordered scale it is:** a five-bar gauge filled to the chosen level, and a dial glyph
  at "Auto". Model keeps a menu; worktree is a toggle chip that reveals the branch field, with the
  `.claude/worktrees/<name>` destination spelled out in the footer.
- **Quick starts:** up to three of the project's recent first prompts as pills under the card; clicking one
  fills the editor.

## Consequences
- `ProjectIconCache` gains a cached average-colour lookup, invalidated with the icon (ADR-076).
- Custom views inside a `Menu` label need `.menuStyle(.button)` + `.buttonStyle(.plain)`;
  `.borderlessButton` renders only the label's text and image, and view-level `.opacity` is dropped in that
  path — bar fills have to be in the colour.
- New smoke keys (ADR-038): `-ClinicDraftPromptOnLaunch <text>` and `-ClinicDraftEffortOnLaunch <level>`,
  alongside the existing `-ClinicNewSessionScreenOnLaunch`.
