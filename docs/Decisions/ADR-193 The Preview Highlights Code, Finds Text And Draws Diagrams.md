---
status: accepted (built 2026-10-10)
date: 2026-10-10
amends: "[[ADR-191 The Files Pane Renders Markdown]] (its *What this does not do*: highlighting, find, Mermaid), [[ADR-058 Third-Party Packages Allowed]] (Mermaid bundled)"
tags: [adr, editor, ui, panel, markdown]
---
# ADR-193: The preview highlights code, finds text and draws diagrams

## Context
[[ADR-191 The Files Pane Renders Markdown]] left three things out of the preview: syntax highlighting in
fenced code, find (⌘F), and Mermaid diagrams. Asked what blocked each, the answer was that none was
blocked, only unbuilt. User (2026-10-10): *"That sounds good, but let's pack it into the same PR."*

## Decision

### Fenced code is highlighted by the editor's own grammars, in the editor's colours
- Two ways were weighed: bundle highlight.js in the page, or highlight in Swift with the tree-sitter
  grammars Clinic already ships with CodeEditLanguages. **Tree-sitter.** It adds no script to the page,
  and a fence reads in the same colours as the file it came from.
- `MarkdownCodeHighlighter` walks the cmark document before rendering. A code block whose info string
  names a language the editor knows is parsed with that grammar and its highlights query. It is
  replaced by an HTML block of `<span class="hl-…">`s carrying the block's own `data-sourcepos`, so
  the split view's scroll sync still finds it. Fence words people write are mapped to a file name the
  language detector knows (`ts`, `sh`, `py`, `objc`, `dockerfile`, …). Anything else stays cmark's plain
  `<pre>`, and so does Markdown inside Markdown.
- Captures are resolved exactly as CodeEditSourceEditor's one-shot highlighter resolves them, and mapped
  onto the theme's seven buckets (`CaptureBucket`, a copy of `EditorTheme`'s private table). The page's
  stylesheet gives each `hl-` class the colour `EditorThemes.current` gives that bucket, bold and italic
  included.
- Queries are loaded per language into a cache of the preview's own. `TreeSitterModel.shared` would
  serve them, but its queries are lazy properties the editor initialises on the main thread, and the
  preview renders on another.

### Find is a bar over the page
- WebKit on the Mac has no find bar, only `WKWebView.find(_:configuration:)`, which selects and scrolls
  to one match at a time. `PreviewFinder` drives it, and `PreviewFindBar` draws a field, *Not found*,
  previous, next and close over the preview's top-right corner. Return goes to the next match, Escape
  closes, ⌘G and ⇧⌘G step through matches. Matching ignores case and wraps.
- A changed query searches again from the top. A search from the current selection would start past
  the match a shorter query had already selected.
- **⌘F belongs to whichever side has the keyboard.** `PreviewWebView` answers ⌘F, ⌘G and ⇧⌘G only while
  the focus is inside it, because key equivalents reach every view in the window. In Split, ⌘F in the
  editor is still the editor's find. The header also gains a find button while the preview shows, so
  the bar can be reached without first clicking into the page.

### Mermaid is bundled, and loaded only by a page that has a diagram
- **mermaid 12.0.0** (MIT), `dist/mermaid.min.js`, is vendored at `Sources/Clinic/Vendor/Mermaid` with its
  licence and provenance, and bundled as a resource. It is 5.3 MB, which is the cost. It fetches nothing
  at runtime and uses no `eval`. 12.1.0 was not yet two weeks old.
- `AppAssetScheme` serves it as `clinic-app:///mermaid.min.js`, and nothing else: it holds a list of
  the names it will serve. The page's CSP adds that scheme, and only that scheme, to `script-src`.
  `GitHubHTMLDocument.page` takes it as `appScheme`.
- The page script loads Mermaid on the first `mermaid` fence and draws each diagram with
  `securityLevel: 'strict'`, in Mermaid's dark or default theme to match. Each drawing is kept by its
  source, so a re-render while typing elsewhere puts the same SVG back rather than redrawing it. A
  diagram that will not parse shows Mermaid's message above its source, never a broken picture.

## Consequences
- `MarkdownRenderer.swift` gains `MarkdownCodeHighlighter` and `CaptureBucket`. `MarkdownPreview.swift`
  gains `AppAssetScheme`, `PreviewFinder`, `PreviewWebView` and `PreviewFindBar`. `EditorModel` gains
  `previewFindRequest`, and `previewFindSeed` for the smoke seam.
- `project.yml` excludes `Sources/Clinic/Vendor` from sources and bundles `mermaid.min.js` as a resource.
- Smoke seam: `-ClinicPreviewFindOnLaunch <text>`, after `-ClinicOpenLinkAfterLaunch`, opens the find bar
  searching for that text.
- Verified in Clinic Dev on 2026-10-10 with a test file outside the repository: Swift, Bash and TypeScript
  fences in the editor's colours, an unknown language plain, a Mermaid flowchart drawn, a broken one
  showing its parse error over its source, and the seeded find selecting the first match. The diagram
  stayed drawn across a re-render. The first try of the seeded find did nothing, because the query was
  set before the bar's `onChange` existed. The bar now searches when it appears, which also re-runs a
  query kept from before. Not exercised: typing in the find bar, ⌘G, ⌘F inside the page, light
  appearance.
