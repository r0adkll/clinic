---
status: accepted
date: 2026-09-16
supersedes: two of ADR-160's "not in v1" items
tags: [adr, ui, sessions, sidebar]
---
# ADR-161: Drafts show in the sidebar, and saved prompts are edited in the composer

## Context
[[ADR-160 Composer Drafts Persist And Prompts Can Be Saved]] kept each project's unsent composer on disk
and added saved prompts. It left out any sign outside the composer that a project has a draft, and any
place to manage saved prompts beyond a pill's context menu.

User (2026-09-16), choosing from that list: *"Let's do #1, #2 (For this lets just do something on the
new session screen and skip a settings pane)"*.

[[ADR-055 No Prompt Composer]] still rules out Collins's draft *rows*, so the sidebar gets a mark, not a
row.

## Decision
### A draft in the sidebar
- **A pencil beside the project's count** while the project has a draft.
  - It is always shown, not only on hover, because the point is to notice it.
  - It is drawn in the accent colour, with the start of the draft in its tooltip.
  - Clicking it opens the composer, which restores the draft, the same as clicking the header.
- **The project menu** says *Continue Draft* instead of *New Session* while there is a draft. It also
  offers *Discard Draft*, which works whether or not the composer is open this run.
- **An empty project's placeholder row** reads *Continue Draft*, with the pencil, instead of
  *New Session*.

### Editing saved prompts
- **A button at the end of the Saved row** (sliders glyph) opens a popover, *Saved Prompts*. So does
  *Edit Saved Prompts…* in a pill's context menu. It has:
  - two sections: this project's prompts, then *Every Project*;
  - on each row, an optional **title** (the placeholder is the start of the text), the **text**
    (up to six lines), a **scope** button (folder or globe) that moves the prompt between the sections,
    and **delete**;
  - **drag to reorder** within a section. Order is the user's from then on, although saving a prompt
    again still moves it to the front.
- **A title replaces the snippet on the prompt's pill.** The tooltip still shows the full text.
- **Edits land as they are typed**, like the draft beside them. A prompt whose text is emptied stays in
  the popover while it is being edited, never appears as a pill, and is removed when the popover
  closes.
- No Settings pane, as the user asked.

## Consequences
- `SavedPrompt` gains an optional `title`. Older files decode without it.
- `ComposerLibrary` gains `updatePrompt`, `removeBlankPrompts`, and `movePrompts(in:fromOffsets:toOffset:)`,
  which reorders one scope inside the slots it already holds so the other scopes do not move. It is
  written in Foundation, because `move(fromOffsets:toOffset:)` is SwiftUI's.
- `TabStore.discardDraft(projectPath:)` covers a draft that is only on disk.
- `ProjectHeader`, `ProjectMenu` and `NewSessionPlaceholderRow` read `ComposerLibraryModel` from the
  environment.
- Checked in a smoke instance through the accessibility API, seeded with a draft and two saved prompts:
  - the pencil and *Continue Draft* rendered, with the draft in the tooltip;
  - the popover listed both sections;
  - delete and the scope button reached `composer.json`;
  - *Discard Draft* from the project menu removed the draft and the mark.

  Typing a title was **not** checked end to end: setting an `AXValue` changes the field without
  reaching SwiftUI's binding. The model call behind it is unit-tested.
