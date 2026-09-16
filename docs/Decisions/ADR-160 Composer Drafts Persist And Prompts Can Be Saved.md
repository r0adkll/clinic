---
status: accepted
date: 2026-09-16
supersedes: ADR-071's "unsent text is kept in memory per project while the app runs"
tags: [adr, ui, sessions, persistence]
---
# ADR-160: Composer drafts persist, and prompts can be saved

## Context
[[ADR-071 New Session Screen]] kept a project's unsent composer in memory only, so a quit or a crash
lost it. The screen's ✕ said *Discard (⌘W)*, but ⌘W only closed the screen and kept the text in memory,
so the button and the shortcut named the same thing and did different things. The quick starts
([[ADR-082 New Session Screen Composer]], [[ADR-117 The Composer Suggests Tasks]]) offered recent first
prompts and tasks, but nothing the user had picked to keep.

User (2026-09-16): *"It would be nice if we could save any typed text in the new session screen as a
draft if we close it (per project) and maybe a way to save prompts as drafts that we could pull from
again."*

[[ADR-055 No Prompt Composer]] ruled out Collins's draft *rows* in the sidebar. That still holds: a draft
here lives inside the composer, not as a row in the sidebar.

## Decision
### Drafts
- **Each project's unsent composer is kept on disk**:
  - what is kept: the prompt, model, effort, worktree toggle, branch name, worktree base and linked task;
  - when: written as it changes, debounced, and flushed on quit;
  - where it comes back: opening that project's composer restores it, including after a relaunch.
- **A draft is text, not settings.** A composer with no prompt, no branch name and no task is not
  kept, because the model and worktree defaults are already remembered per project.
- **Closing keeps the draft.** The ✕ now closes, like ⌘W and like selecting a tab. **Discard Draft**
  in the footer, shown only while there is a draft, throws it away. Send spends it.
- Starting a composer from a task ([[ADR-114 Starting A Session From A Task]]) still replaces the
  project's draft.

### Saved prompts
- **A bookmark button in the control bar**, beside Send, saves the prompt for this project. It is filled
  in while the text is already saved, and clicking it then removes the saved prompt.
- **A Saved row**, first of the quick-start rows, shows this project's saved prompts, then those saved
  for every project, newest first:
  - clicking one fills the editor, the same as a Recent prompt;
  - its context menu moves it between *this project* and *every project* (a globe marks these), or
    deletes it;
  - a Recent prompt that is also saved shows only in Saved.
- Prompts match by their words, ignoring case and spacing. Saving text that is already offered moves it
  to the front instead of adding a copy. Saving for every project absorbs every project's copy.
- Only the text is saved, not the settings: a saved prompt is something to start from, and a worktree
  name is different for every use.

### Storage
- `ComposerLibrary`, a pure type in ClinicCore, holds the drafts and saved prompts. `ComposerLibraryStore`
  writes it to its own file, `Clinic/composer.json`. It is not in `state.json`: a keystroke must not
  rewrite that file, or redraw the views that observe `SessionStore.state`.
- It decodes tolerantly, like `ClinicState`: a part that fails to decode is dropped, and the rest of
  the file still loads.

## Consequences
- `TabStore.composer` (`ComposerLibraryModel`) is in the environment. `NewSessionScreen` records
  `draft.persisted` with `onChange(initial:)`. `discardDraft` and a sent draft clear the entry on disk.
- `ComposerDraft` equality ignores `updatedAt`, so a draft recorded again unchanged is not written.
- Not in v1:
  - any sign outside the composer that a project has a draft;
  - a window for managing saved prompts;
  - saving a prompt's model and effort with it;
  - a keyboard shortcut for saving.
- Checked in a smoke instance through the accessibility API: a typed draft reached `composer.json`, the
  bookmark saved it and a Saved pill appeared, the draft came back after closing with ✕, killing the
  app and relaunching, and Discard Draft emptied `drafts` while the saved prompt stayed.
