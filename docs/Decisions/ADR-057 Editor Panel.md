---
status: accepted
date: 2026-09-07
tags: [adr, editor, ui, milestone-3]
---
# ADR-057: Editor panel

## Context
User (2026-09-07): "Having the editor panel would be great for quick checks and at a minimum syntax highlighting; the editing feature is just a nice bonus." Collins: GtkSourceView editor with file tree, quick open, "agent files", external-change reload, follows worktrees, pop-out window. Third-party packages are allowed ([[ADR-058 Third-Party Packages Allowed]]), so highlighting comes from a maintained tree-sitter editor rather than a home-grown tokenizer.

## Decision
- **Where**: right column like the other pages (⌘⇧E, footer "Files" button). Root = the tab's current directory's repository top level when inside a work tree, else the directory itself, so a `-w` session shows its worktree.
- **Layout**: a narrow file tree (directories first, hidden entries behind a toggle, `.gitignore` respected via `git ls-files`) beside a code view; a quick-open field (⌘⇧O) with fuzzy ranking over the index; an **Agent files** list of files the session wrote (from transcript `tool_use` blocks) for one-click checks.
- **Code view**: CodeEdit's `SourceEditor` (tree-sitter highlighting for ~50 languages, gutter, bracket matching, find, optional minimap) with an `EditorTheme` derived from system colours for light/dark. Language from `CodeLanguage.detectLanguageFrom(url:)`.
- **Editing**: allowed; dirty marker in the header; ⌘S saves; external changes reload when the buffer is clean and prompt when dirty. No multi-file tabs; a "recent files" list stands in.
- **Not now**: pop-out window, single-column narrow mode, find/replace inside the file (use the system find bar of NSTextView, which comes free), `open_in_editor` tool wiring (next batch), image preview.

## Consequences
- `ClinicCore/Editor`: `FuzzyMatcher`, `FileIndex`; `SessionSummary.recentFiles`.
- Unknown languages fall back to plain text.
