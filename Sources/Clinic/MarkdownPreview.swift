import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ClinicCore

/// How the Files pane shows a Markdown file (ADR-191): its source, the source beside what it
/// renders to, or the rendered page alone.
enum MarkdownMode: String, CaseIterable, Identifiable {
    case source, split, preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: "Source"
        case .split: "Source and Preview"
        case .preview: "Preview"
        }
    }

    var symbol: String {
        switch self {
        case .source: "chevron.left.forwardslash.chevron.right"
        case .split: "rectangle.split.2x1"
        case .preview: "doc.richtext"
        }
    }
}

/// Carries the editor's scroll position to the preview beside it, in source lines — fractional, so a
/// long paragraph scrolls smoothly rather than in steps. A plain object, not observed state: it fires
/// many times a second, and nothing in SwiftUI needs to redraw for it.
@MainActor
final class MarkdownScrollSync {
    var onLine: ((Double) -> Void)?
    func sourceScrolled(to line: Double) { onLine?(line) }
}

/// The three choices, as header buttons that read as one control.
struct MarkdownModePicker: View {
    @Binding var mode: MarkdownMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MarkdownMode.allCases) { m in
                PaneIconButton(symbol: m.symbol, help: "Show the \(m.title.lowercased())", isOn: mode == m) { mode = m }
            }
        }
    }
}

/// The Files pane's body for a Markdown file. The editor keeps its place in the hierarchy across
/// Source and Split, so going from one to the other keeps the cursor, scroll and undo; the layout
/// turns from side by side to one above the other below 640 pt, as the Diff panel's pictures do
/// (ADR-189).
struct MarkdownEditorView: View {
    @Bindable var model: EditorModel
    @State private var sync = MarkdownScrollSync()

    var body: some View {
        let mode = EditorPrefs.shared.markdownMode
        GeometryReader { geo in
            let wide = geo.size.width >= 640
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                if mode != .preview {
                    CodeView(model: model, sync: mode == .split ? sync : nil)
                        .id(model.loadGeneration)
                        .clipped()
                }
                if mode == .split {
                    Rectangle().fill(Color(nsColor: .separatorColor))
                        .frame(width: wide ? 1 : nil, height: wide ? nil : 1)
                }
                if mode != .source {
                    MarkdownPreview(model: model, sync: mode == .split ? sync : nil)
                }
            }
        }
    }
}

/// The rendered page. Rendering runs off the main actor and is debounced while typing; a new render
/// replaces the page's content in place, so the reader's place survives an edit — theirs or the
/// agent's (ADR-191).
struct MarkdownPreview: View {
    let model: EditorModel
    var sync: MarkdownScrollSync?
    @Environment(\.colorScheme) private var colorScheme
    @State private var html: String?
    @State private var finder = PreviewFinder()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: .textBackgroundColor)
            if let html, let path = model.openPath {
                MarkdownWebView(html: html, path: path, root: model.root, dark: colorScheme == .dark,
                                sync: sync, jumpLine: model.jump?.line, finder: finder,
                                openFile: { model.open(absolute: $0) },
                                openWikiLink: { target in Task { await model.openWikiLink(target) } })
            }
            if finder.isShown { PreviewFindBar(finder: finder).padding(8) }
        }
        .onChange(of: model.previewFindRequest) {
            finder.show()
            if let seed = model.previewFindSeed { model.previewFindSeed = nil; finder.query = seed }
        }
        .onChange(of: model.openPath) { finder.close() }
        .task(id: model.text) {
            // The first render is immediate; one while typing waits for a pause.
            if html != nil { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let source = model.text
            let rendered = await Task.detached(priority: .userInitiated) { MarkdownRenderer.html(source) }.value
            guard !Task.isCancelled else { return }
            html = rendered
        }
    }
}

private struct MarkdownWebView: NSViewRepresentable {
    let html: String
    let path: String
    let root: String
    let dark: Bool
    let sync: MarkdownScrollSync?
    let jumpLine: Int?
    let finder: PreviewFinder
    let openFile: (String) -> Void
    let openWikiLink: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PreviewWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(context.coordinator.files, forURLScheme: LocalFileScheme.name)
        config.setURLSchemeHandler(AppAssetScheme(), forURLScheme: AppAssetScheme.name)
        let view = PreviewWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        update(view, context: context)
        return view
    }

    func updateNSView(_ view: PreviewWebView, context: Context) { update(view, context: context) }

    private func update(_ view: PreviewWebView, context: Context) {
        let c = context.coordinator
        finder.webView = view
        view.finder = finder
        c.openFile = openFile
        c.openWikiLink = openWikiLink
        sync?.onLine = { [weak c, weak view] line in
            guard let c, let view else { return }
            c.reveal(line, in: view)
        }
        c.show(html, path: path, root: root, dark: dark, jumpLine: jumpLine, in: view)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let files = LocalFileScheme()
        var openFile: ((String) -> Void)?
        var openWikiLink: ((String) -> Void)?
        /// What the page was built for: a different file or appearance loads a new page; anything
        /// else is new content for the page already there.
        private var pageKey: String?
        private var shownHTML: String?
        private var loading = false
        /// Content or a line that arrived while the page was still loading.
        private var pendingHTML: String?
        private var pendingLine: Double?
        private var baseURL: URL?

        func show(_ html: String, path: String, root: String, dark: Bool, jumpLine: Int?, in view: WKWebView) {
            let key = "\(path)\n\(dark)"
            if key != pageKey {
                pageKey = key
                shownHTML = html
                pendingHTML = nil
                pendingLine = jumpLine.map(Double.init)
                loading = true
                let directory = (path as NSString).deletingLastPathComponent
                // Pictures are served from the repository, so `../assets/shot.png` in `docs/` shows;
                // or, for a file outside it, from the file's own folder.
                files.root = path.hasPrefix(root + "/") ? root : directory
                // The page *is* the file's folder under the scheme, so its relative links and images
                // resolve where they would on GitHub.
                let base = LocalFileScheme.url(directory: directory)
                baseURL = base
                let page = GitHubHTMLDocument.page(body: "<article id=\"clinic-md\" data-dark=\"\(dark)\">\(html)</article>", dark: dark,
                                                   reportsHeight: false,
                                                   extraCSS: Self.css(dark: dark) + CaptureBucket.css(for: EditorThemes.current),
                                                   localScheme: LocalFileScheme.name, appScheme: AppAssetScheme.name,
                                                   script: Self.script)
                view.loadHTMLString(page, baseURL: base)
                return
            }
            guard html != shownHTML else { return }
            shownHTML = html
            if loading { pendingHTML = html; return }
            view.callAsyncJavaScript("window.clinicRender(html)", arguments: ["html": html], in: nil, in: .page)
        }

        func reveal(_ line: Double, in view: WKWebView) {
            if loading { pendingLine = line; return }
            view.callAsyncJavaScript("window.clinicReveal(line)", arguments: ["line": line], in: nil, in: .page)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loading = false
            if let html = pendingHTML {
                pendingHTML = nil
                webView.callAsyncJavaScript("window.clinicRender(html)", arguments: ["html": html], in: nil, in: .page)
            }
            if let line = pendingLine {
                pendingLine = nil
                reveal(line, in: webView)
            }
        }

        /// Nothing navigates in place (ADR-090). A link to a file opens it in the pane; a wiki link
        /// finds its note; anything with a scheme of its own goes to the system.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            switch action.navigationType {
            case .other:
                // `loadHTMLString` itself.
                decisionHandler(url.scheme == "about" || url == baseURL ? .allow : .cancel)
            case .linkActivated:
                decisionHandler(.cancel)
                follow(url)
            default:
                decisionHandler(.cancel)
            }
        }

        private func follow(_ url: URL) {
            if url.scheme == "clinic-wiki" {
                let target = String(url.absoluteString.dropFirst("clinic-wiki:".count)).removingPercentEncoding ?? ""
                openWikiLink?(target)
                return
            }
            if url.isFileURL || url.scheme == LocalFileScheme.name {
                // The page's own address with an anchor: the script scrolls to those.
                if url.fragment != nil, url.path == baseURL?.path { return }
                let path = url.path(percentEncoded: false)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { NSSound.beep(); return }
                if isDirectory.boolValue { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { openFile?(path) }
                return
            }
            NSWorkspace.shared.open(url)
        }

        /// A reading page, not a comment: a step larger than the PR panel's 13 px, held to a column a
        /// line of prose can be read across, and padded off the pane's edges.
        static func css(dark: Bool) -> String {
            let muted = dark ? "#9198a1" : "#59636e"
            return """
            html { scroll-padding-top: 12px; }
            body { font-size: 14px; line-height: 1.6; }
            #clinic-md { max-width: 880px; margin: 0 auto; padding: 16px 22px 28px; }
            #clinic-md > *:first-child { margin-top: 0 !important; }
            h1 { font-size: 1.75em; } h2 { font-size: 1.4em; } h3 { font-size: 1.18em; }
            h1, h2, h3, h4 { margin-top: 22px; }
            code { font-size: 12.5px; }
            p, ul, ol, blockquote, table, pre { margin-bottom: 14px; }
            li:has(> input[type=checkbox]:first-child) { list-style: none; }
            li > input[type=checkbox]:first-child { margin: 0 .45em 0 -1.35em; vertical-align: -1px; }
            pre.front-matter { color: \(muted); font-size: 12px; }
            a.wiki-link { border-bottom: 1px dotted currentColor; }
            a.wiki-link:hover { text-decoration: none; border-bottom-style: solid; }
            .mermaid-diagram { margin-bottom: 14px; text-align: center; overflow-x: auto; }
            .mermaid-diagram svg { max-width: 100%; height: auto; }
            .mermaid-diagram.mermaid-error { text-align: left; }
            .mermaid-error > p { color: #f85149; font-size: 12px; margin: 0 0 6px; }
            section.footnotes { font-size: .9em; color: \(muted); border-top: 1px solid var(--borderColor-default); margin-top: 24px; padding-top: 8px; }
            """
        }

        /// The page's half of the preview: heading anchors as GitHub names them, GitHub's `> [!NOTE]`
        /// alerts (cmark-gfm leaves them as quotes; GitHub converts them after), Obsidian wiki links, in-page anchors that scroll here rather than becoming a navigation, replacing content
        /// in place, and following the editor's line.
        static let script = """
        (function () {
          var root = document.getElementById('clinic-md');
          function slug(text) {
            return text.trim().toLowerCase().replace(/[^\\p{L}\\p{N}\\s_-]/gu, '').replace(/\\s/g, '-');
          }
          function decorate() {
            var seen = Object.create(null);
            root.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(function (h) {
              var s = slug(h.textContent), n = seen[s];
              seen[s] = n === undefined ? 0 : n + 1;
              h.id = n === undefined ? s : s + '-' + (n + 1);
            });
            root.querySelectorAll('blockquote').forEach(function (q) {
              var p = q.firstElementChild, first = p && p.tagName === 'P' ? p.firstChild : null;
              var m = first && first.nodeType === 3 && /^\\s*\\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\\]\\s*/i.exec(first.nodeValue);
              if (!m) return;
              var kind = m[1].toLowerCase(), title = document.createElement('p');
              first.nodeValue = first.nodeValue.slice(m[0].length);
              if (first.nextSibling && first.nextSibling.tagName === 'BR' && !first.nodeValue) p.removeChild(first.nextSibling);
              title.className = 'markdown-alert-title';
              title.textContent = kind.charAt(0).toUpperCase() + kind.slice(1);
              var alert = document.createElement('div');
              alert.className = 'markdown-alert markdown-alert-' + kind;
              if (q.hasAttribute('data-sourcepos')) alert.setAttribute('data-sourcepos', q.getAttribute('data-sourcepos'));
              alert.appendChild(title);
              while (q.firstChild) alert.appendChild(q.firstChild);
              if (!p.textContent.trim() && !p.children.length) alert.removeChild(p);
              q.parentNode.replaceChild(alert, q);
            });
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT), hits = [], node;
            while ((node = walker.nextNode())) {
              if (node.nodeValue.indexOf('[[') < 0 || node.parentElement.closest('code, pre, a')) continue;
              hits.push(node);
            }
            var pattern = /!?\\[\\[([^\\[\\]|]+)(?:\\|([^\\[\\]]+))?\\]\\]/g;
            hits.forEach(function (text) {
              var value = text.nodeValue, frag = document.createDocumentFragment(), last = 0, m;
              pattern.lastIndex = 0;
              while ((m = pattern.exec(value))) {
                frag.appendChild(document.createTextNode(value.slice(last, m.index)));
                var a = document.createElement('a');
                a.href = 'clinic-wiki:' + encodeURIComponent(m[1].trim());
                a.className = 'wiki-link';
                a.textContent = (m[2] || m[1]).trim();
                frag.appendChild(a);
                last = pattern.lastIndex;
              }
              if (last === 0) return;
              frag.appendChild(document.createTextNode(value.slice(last)));
              text.parentNode.replaceChild(frag, text);
            });
          }
          function start(e) { return parseInt(e.getAttribute('data-sourcepos'), 10); }
          function end(e) { return parseInt(e.getAttribute('data-sourcepos').split('-')[1], 10); }
          function top(e) { return e.getBoundingClientRect().top + window.scrollY; }
          window.clinicReveal = function (line) {
            var blocks = Array.prototype.filter.call(root.children, function (e) { return e.hasAttribute('data-sourcepos'); });
            if (!blocks.length || line < start(blocks[0])) { window.scrollTo(0, 0); return; }
            var i = 0;
            while (i + 1 < blocks.length && start(blocks[i + 1]) <= line) i++;
            var el = blocks[i], next = blocks[i + 1], s = start(el), e = next ? start(next) : end(el) + 1;
            var y0 = top(el), y1 = next ? top(next) : y0 + el.offsetHeight;
            var f = e > s ? Math.min(1, Math.max(0, (line - s) / (e - s))) : 0;
            window.scrollTo(0, Math.max(0, y0 + (y1 - y0) * f - 12));
          };
          // Mermaid (ADR-191): Clinic's bundled copy, fetched only by a page that has a diagram, and each
          // diagram drawn once per source so typing elsewhere does not redraw it.
          var dark = root.getAttribute('data-dark') === 'true', waiting = null, drawn = Object.create(null), serial = 0;
          function withMermaid(then) {
            if (window.mermaid) return then();
            if (waiting) { waiting.push(then); return; }
            waiting = [then];
            var s = document.createElement('script');
            s.src = 'clinic-app:///mermaid.min.js';
            s.onload = function () {
              window.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
                                          theme: dark ? 'dark' : 'default' });
              var queue = waiting; waiting = []; queue.forEach(function (f) { f(); });
            };
            document.head.appendChild(s);
          }
          function diagrams() {
            var blocks = Array.prototype.slice.call(root.querySelectorAll('pre > code.language-mermaid'));
            if (!blocks.length) return;
            withMermaid(function () {
              blocks.forEach(function (code) {
                var pre = code.parentNode;
                if (!root.contains(pre)) return;
                var source = code.textContent, box = document.createElement('div');
                box.className = 'mermaid-diagram';
                if (pre.hasAttribute('data-sourcepos')) box.setAttribute('data-sourcepos', pre.getAttribute('data-sourcepos'));
                pre.parentNode.replaceChild(box, pre);
                if (drawn[source]) { box.innerHTML = drawn[source]; return; }
                box.appendChild(pre);
                window.mermaid.render('clinic-mermaid-' + (++serial), source).then(function (result) {
                  drawn[source] = result.svg;
                  box.innerHTML = result.svg;
                }, function (error) {
                  var note = document.createElement('p');
                  note.textContent = 'Mermaid: ' + ((error && error.message) || error);
                  box.classList.add('mermaid-error');
                  box.insertBefore(note, box.firstChild);
                });
              });
            });
          }
          window.clinicRender = function (html) { root.innerHTML = html; decorate(); diagrams(); };
          document.addEventListener('click', function (event) {
            var a = event.target.closest && event.target.closest('a[href^="#"]');
            if (!a) return;
            event.preventDefault();
            var id = decodeURIComponent(a.getAttribute('href').slice(1));
            var target = document.getElementById(id) || document.getElementsByName(id)[0];
            if (target) target.scrollIntoView({ block: 'start' });
          });
          decorate();
          diagrams();
        })();
        """
    }
}

/// Serves the files a Markdown page refers to — its pictures — from disk, under a scheme of Clinic's
/// own (ADR-191). WebKit will not let a page loaded from a string read `file:` URLs, and widening its
/// sandbox to the disk would be more than a README needs: this hands over only what lies below
/// `root`, and only to the page that asked.
@MainActor
final class LocalFileScheme: NSObject, WKURLSchemeHandler {
    static let name = "clinic-file"
    var root = "/"

    static func url(directory: String) -> URL? {
        var c = URLComponents()
        c.scheme = name
        c.host = ""
        c.path = directory.hasSuffix("/") ? directory : directory + "/"
        return c.url
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let path = (url.path(percentEncoded: false) as NSString).standardizingPath
        guard path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/"),
              let data = FileManager.default.contents(atPath: path) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let type = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Serves Clinic's own bundled scripts to the preview — Mermaid, today — under a scheme of their own,
/// the only one the page's CSP lets a script come from besides the page's nonce (ADR-191). Only the
/// names listed here are served.
final class AppAssetScheme: NSObject, WKURLSchemeHandler {
    static let name = "clinic-app"
    private static let assets = ["mermaid.min.js": "text/javascript"]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let type = Self.assets[url.lastPathComponent],
              let file = Bundle.main.url(forResource: url.lastPathComponent, withExtension: nil),
              let data = try? Data(contentsOf: file) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

// MARK: - Find (ADR-191)

/// Find in the rendered page. WebKit on the Mac has no find bar of its own, only `find(_:configuration:)`,
/// which selects and scrolls to one match at a time; this is the state of the bar Clinic draws over it.
@MainActor
@Observable
final class PreviewFinder {
    var isShown = false
    var query = ""
    /// The last search found nothing.
    private(set) var missing = false
    /// Bumped to put the keyboard in the field, again if the bar is already open.
    private(set) var focusRequest = 0
    @ObservationIgnored weak var webView: WKWebView?

    func show() { isShown = true; focusRequest += 1 }

    func close() {
        guard isShown else { return }
        isShown = false
        missing = false
        if let webView { webView.window?.makeFirstResponder(webView) }
    }

    /// From the top, as the query changes: the match a shorter query selected may be the one a longer
    /// query wants, and a search from the selection would start past it.
    func restart() {
        guard let webView else { return }
        guard !query.isEmpty else { missing = false; return }
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()") { [weak self] _, _ in
            MainActor.assumeIsolated { self?.step(forward: true) }
        }
    }

    func step(forward: Bool) {
        guard let webView, !query.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(query, configuration: configuration) { [weak self] result in
            self?.missing = !result.matchFound
        }
    }
}

/// The page's web view, which takes ⌘F, ⌘G and ⇧⌘G while it has the keyboard. Key equivalents reach
/// every view in the window, so it answers only when the focus is inside it: in Split, ⌘F in the
/// editor stays the editor's find.
final class PreviewWebView: WKWebView {
    weak var finder: PreviewFinder?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let finder, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
        case ("f", [.command]): finder.show(); return true
        case ("g", [.command]) where finder.isShown: finder.step(forward: true); return true
        case ("g", [.command, .shift]) where finder.isShown: finder.step(forward: false); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

/// The bar: a field, whether it found anything, previous and next, and close. Return finds the next
/// match, Escape closes.
private struct PreviewFindBar: View {
    @Bindable var finder: PreviewFinder
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Find in preview", text: $finder.query)
                .textFieldStyle(.plain)
                .font(.system(size: PaneMetrics.label))
                .frame(width: 170)
                .focused($focused)
                .onSubmit { finder.step(forward: true) }
                .onKeyPress(.escape) { finder.close(); return .handled }
            if finder.missing {
                Text("Not found").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            }
            PaneIconButton(symbol: "chevron.up", help: "Previous match (⇧⌘G)") { finder.step(forward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            PaneIconButton(symbol: "chevron.down", help: "Next match (⌘G)") { finder.step(forward: true) }
                .keyboardShortcut("g", modifiers: .command)
            PaneIconButton(symbol: "xmark", help: "Close (Esc)") { finder.close() }
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 32)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .onChange(of: finder.query, initial: true) { finder.restart() }
        .onChange(of: finder.focusRequest, initial: true) { focused = true }
    }
}

