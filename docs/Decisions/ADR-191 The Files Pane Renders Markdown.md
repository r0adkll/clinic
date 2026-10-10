---
status: accepted (built 2026-10-10)
date: 2026-10-10
amends: "[[ADR-081 Files Panel Focus Modes]] (a Markdown file's viewer), [[ADR-058 Third-Party Packages Allowed]] (swift-cmark adopted)"
tags: [adr, editor, ui, panel, markdown]
---
# ADR-191: The Files pane renders Markdown

## Context
User (2026-10-10): *"It would be nice to have a toggle to view Markdown files as richly rendered (maybe
options for code only, side-by-side, rendered only) OR have a wysiwyg type editor (like Obsidian)."*

Until now a Markdown file in the Files pane was source with `MarkdownHighlighter`'s colours
([[ADR-081 Files Panel Focus Modes]]). In a session, most of the Markdown in front of you is there to be
read: a plan the agent wrote, a README, an ADR in this very vault, notes. Reading `**bold**`,
`| pipes |` and `[[wiki links]]` as punctuation is the job the request is about.

## Options
1. **Three views: Source, Split, Preview**, the rendered side an HTML page from a CommonMark renderer.
2. **A WYSIWYG editor like Obsidian's live preview**, where the syntax under the caret shows and the rest
   renders in place. Obsidian builds this on CodeMirror 6 decorations. CodeEditSourceEditor
   ([[ADR-057 Editor Panel]]) has highlight providers, and they only colour text: they cannot hide
   characters, set a heading's size or line height, or put a table or a picture inline. A web-based
   rich-text editor (Milkdown, TipTap and the like) can do all of it, but it edits a document tree and
   writes Markdown back out of it. That rewrites spacing, list markers and table padding in a file that
   git, the agent and the user's other editors also care about.
3. **Render with Apple's `AttributedString(markdown:)`.** Inline syntax only: no tables, task lists or
   block quotes worth the name.

## Decision
Option 1. The WYSIWYG editor is not built, for the reasons in option 2. If it comes, it will be a
separate decision with its own editor.

### Three views, chosen in the header, remembered for every pane
- A Markdown file's header carries three buttons: **Source** (`</>`), **Split** and **Preview**. They
  are `PaneIconButton`s like every other control in that band ([[ADR-103 File Browser Chrome Is Sized To
  Be Hit]]), with the one in use lit.
- The choice is `EditorPrefs.markdownMode`, persisted as `ClinicEditorMarkdownMode` and shared by every
  Files pane and file window, as the tree toggle is. It records how you read Markdown, not how one pane
  is set up.
- **Preview is the default**, for the reason in the context. Source is one click or one chord away.
- **Panel → Cycle Markdown View**, ⌘⌃P, rebindable ([[ADR-073 Rebindable Shortcuts]]), enabled while a
  Files pane showing Markdown is in front. ⌘⇧V is the usual chord elsewhere, and here it is Ghostty's
  paste-from-selection.
- **Split** puts the two side by side when the column is 640 pt or wider, and one above the other when it
  is not (the Diff panel's rule for pictures, [[ADR-189 The File Viewers Draw Pictures]]). It is built
  with `AnyLayout`, so the editor keeps its place in the hierarchy going between Source and Split, and
  with it the cursor, scroll position and undo stack.

### Rendering is cmark-gfm
- `MarkdownRenderer` uses **swiftlang/swift-cmark 0.9.0**: cmark-gfm, GitHub's own fork of the CommonMark
  reference parser, as a SwiftPM C package. It handles tables, task lists, strikethrough, autolinks and
  footnotes, and lets raw HTML through, which READMEs depend on (`<p align="center">`, `<details>`,
  `<img width>`). BSD-2 licence, no network, no Swift dependencies of its own. Recorded in ADR-058.
- The `tagfilter` extension neuters `<script>`, `<iframe>`, `<style>` and the rest, as GitHub does. The
  page also keeps ADR-090's CSP: no script runs but Clinic's own, under a per-page nonce.
- **Front matter** is split off before rendering (`MarkdownDocument.split`, ClinicCore). Every line it
  took is replaced with a blank one, so source positions still match the editor's line numbers. It is
  shown as a muted block above the document, not as the rule and heading CommonMark would make of it.
- The page is `GitHubHTMLDocument`'s, the PR panel's palette and typography, with a reading column on
  top: 14 px type, at most 880 px wide, padded off the pane's edges. Everything that renders Markdown in
  Clinic now looks the same. That stylesheet's tables also stop forcing every cell left, so a `|--:|`
  column is right-aligned, in the PR panel as well.
- The page script does what GitHub does after rendering: heading anchors with GitHub's slugs, and
  `> [!NOTE]`-style alerts turned into the alert blocks the stylesheet already styles.

### The preview is live and keeps your place
- Rendering runs off the main actor, at once on open and after a 150 ms pause while typing.
- A new render replaces the page's content through `callAsyncJavaScript`. The page is not reloaded, so
  the reader's scroll position survives each keystroke, and each save the agent makes while you read.
  A different file or a change of appearance loads a new page.
- **In Split, the preview follows the editor.** `CodeViewBridge`, a `TextViewCoordinator`, reports the
  source line at the top of the editor, fractional so a long paragraph scrolls smoothly. The page finds
  the top-level block whose `data-sourcepos` covers that line and interpolates within it. Only the editor
  drives: two-way sync between views of different heights feeds back on itself, and the editor is where
  the work happens.

### Links go somewhere useful
- A relative link to a file opens it in the same pane. A folder opens in Finder. A web address opens in
  the browser. An in-page anchor scrolls the page. Nothing navigates the web view itself.
- **Obsidian `[[wiki links]]`**, with or without `|alias`, `#heading` or `^block`, become links.
  `MarkdownDocument.resolveWikiLink` finds the note by name anywhere in the tree, preferring the one beside
  the document and then the shallowest, as Obsidian's shortest-path links do. A name with no match says
  so in the pane's error line. This repository's own vault ([[ADR-105 The Vault Lives In The Repo]]) is
  full of them.
- **Pictures load from disk** through `LocalFileScheme`, a `WKURLSchemeHandler` for `clinic-file:`. The
  page's base URL is the file's folder under that scheme, so relative paths resolve as they would on
  GitHub. The handler serves only what lies under the repository root, or under the file's own folder
  for a file outside it. *Found 2026-10-10:* `loadHTMLString` with a `file:` base URL drew every local
  picture broken. WebKit does not let a page loaded from a string read `file:` URLs, and widening its
  sandbox to the disk would be more than a README needs.

### What this does not do
- No syntax highlighting inside fenced code in the preview, and no Mermaid or maths. Each can come when
  someone needs it, through the same page.
- No find (⌘F) inside the preview. Find stays the code view's.
- No embedded `![[note]]` transclusion. An embed is drawn as a link to its note.

## Consequences
- New: `MarkdownRenderer.swift` (cmark-gfm), `MarkdownPreview.swift` (`MarkdownMode`, `MarkdownModePicker`,
  `MarkdownEditorView`, `MarkdownPreview`, the web view and its script, `LocalFileScheme`,
  `MarkdownScrollSync`). ClinicCore: `MarkdownDocument` (front matter, wiki links) and tests.
- `EditorPrefs.markdownMode`; `EditorModel.isMarkdown`, `openWikiLink`. `CodeView` is no longer private,
  takes an optional `MarkdownScrollSync`, and carries `CodeViewBridge`, which [[ADR-192 Terminal File Links
  Open In The Files Pane]] also uses to land on a line.
- `GitHubHTMLDocument.page` takes `localScheme` and a `script`; `csp` takes the scheme.
- `project.yml` gains the `swift-cmark` package (products `cmark-gfm`, `cmark-gfm-extensions`) on the app
  target. ClinicCore stays Foundation-only.
- Verified in Clinic Dev on 2026-10-10: the README with its icon and hero picture loaded through the
  scheme; a GFM test file in wide Split, with a table aligned per column, a task list, strikethrough,
  autolink, wiki links with and without alias, `<details>`, a `<script>` drawn inert as text, a NOTE alert
  and front matter; an ADR in narrow (stacked) Split with the preview following the editor; and a line
  inserted on disk appearing in Preview without a reload or a jump. Not exercised: clicking a link in the
  preview (wiki, relative or anchor), the ⌘⌃P menu item, light appearance, and a file window.
