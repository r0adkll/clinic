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

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let html, let path = model.openPath {
                MarkdownWebView(html: html, path: path, root: model.root, dark: colorScheme == .dark,
                                sync: sync, jumpLine: model.jump?.line,
                                openFile: { model.open(absolute: $0) },
                                openWikiLink: { target in Task { await model.openWikiLink(target) } })
            }
        }
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
    let openFile: (String) -> Void
    let openWikiLink: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(context.coordinator.files, forURLScheme: LocalFileScheme.name)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        update(view, context: context)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) { update(view, context: context) }

    private func update(_ view: WKWebView, context: Context) {
        let c = context.coordinator
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
                let page = GitHubHTMLDocument.page(body: "<article id=\"clinic-md\">\(html)</article>", dark: dark,
                                                   reportsHeight: false, extraCSS: Self.css(dark: dark),
                                                   localScheme: LocalFileScheme.name, script: Self.script)
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
          window.clinicRender = function (html) { root.innerHTML = html; decorate(); };
          document.addEventListener('click', function (event) {
            var a = event.target.closest && event.target.closest('a[href^="#"]');
            if (!a) return;
            event.preventDefault();
            var id = decodeURIComponent(a.getAttribute('href').slice(1));
            var target = document.getElementById(id) || document.getElementsByName(id)[0];
            if (target) target.scrollIntoView({ block: 'start' });
          });
          decorate();
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
