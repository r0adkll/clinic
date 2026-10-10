import Foundation
import cmark_gfm
import cmark_gfm_extensions
import CodeEditLanguages
@preconcurrency import CodeEditSourceEditor
import SwiftTreeSitter
import ClinicCore

/// Markdown to HTML for the Files pane's preview (ADR-191), by cmark-gfm — GitHub's own fork of the
/// CommonMark reference parser, so a README reads here as it reads on GitHub: tables, task lists,
/// strikethrough, autolinks, footnotes, and the raw HTML READMEs lean on (`<p align="center">`,
/// `<details>`, `<img width>`).
///
/// Raw HTML is let through (`CMARK_OPT_UNSAFE`) because the page it lands in is inert: GFM's
/// `tagfilter` neuters `<script>`, `<iframe>`, `<style>` and the rest as GitHub does, and the page's
/// CSP refuses any script but Clinic's own (ADR-090).
///
/// Every block carries `data-sourcepos`, which is how the split view finds the paragraph the editor
/// is looking at.
enum MarkdownRenderer {
    /// Registering the extensions is a one-time global write in cmark-gfm; after it, parsers on any
    /// thread only read the registry.
    private static let registered: Void = { cmark_gfm_core_extensions_ensure_registered() }()
    private static let extensions = ["table", "strikethrough", "autolink", "tagfilter", "tasklist"]

    /// Front matter becomes a muted block above the document rather than a rule and a heading, which
    /// is what CommonMark makes of it.
    static func html(_ markdown: String) -> String {
        _ = registered
        let (frontMatter, body) = MarkdownDocument.split(markdown)
        let options = CMARK_OPT_SOURCEPOS | CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES | CMARK_OPT_VALIDATE_UTF8
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in extensions {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        body.utf8CString.withUnsafeBufferPointer { buffer in
            // The buffer ends in the NUL `utf8CString` adds; cmark is given the bytes before it.
            cmark_parser_feed(parser, buffer.baseAddress, buffer.count - 1)
        }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        MarkdownCodeHighlighter.highlightCodeBlocks(in: document)
        guard let rendered = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(rendered) }
        let html = String(cString: rendered)
        guard let frontMatter, !frontMatter.isEmpty else { return html }
        return "<pre class=\"front-matter\"><code>\(GitHubHTMLDocument.escape(frontMatter))</code></pre>\n" + html
    }
}

/// Colours fenced code in the preview with the grammars and colours the editor uses (ADR-191).
///
/// A block whose info string names a language the editor knows (`swift`, `ts`, `sh`, `py`, …) is parsed
/// with that tree-sitter grammar and its highlights query, resolved exactly as CodeEditSourceEditor's
/// own one-shot highlighter resolves them, and replaced in the document by an HTML block of `<span>`s.
/// Each span carries the class of the editor theme's colour for that capture — `hl-keyword`,
/// `hl-string` — and the page's stylesheet gives each class the editor's colour, so a fence reads as
/// the same code in the editor reads. A block in any other language stays cmark's plain `<pre>`.
enum MarkdownCodeHighlighter {
    static func highlightCodeBlocks(in document: UnsafeMutablePointer<cmark_node>) {
        var blocks: [UnsafeMutablePointer<cmark_node>] = []
        guard let iterator = cmark_iter_new(document) else { return }
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { break }
            if event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator),
               cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK {
                blocks.append(node)
            }
        }
        cmark_iter_free(iterator)

        for block in blocks {
            guard let info = cmark_node_get_fence_info(block).map({ String(cString: $0) }),
                  let word = info.split(whereSeparator: { $0 == " " || $0 == "{" }).first.map({ $0.lowercased() }),
                  let language = language(for: word),
                  let code = cmark_node_get_literal(block).map({ String(cString: $0) }),
                  let spans = highlight(code, in: language),
                  let html = cmark_node_new(CMARK_NODE_HTML_BLOCK) else { continue }
            let position = "\(cmark_node_get_start_line(block)):\(cmark_node_get_start_column(block))-"
                + "\(cmark_node_get_end_line(block)):\(cmark_node_get_end_column(block))"
            let markup = "<pre data-sourcepos=\"\(position)\"><code class=\"language-\(GitHubHTMLDocument.escape(word))\">"
                + spans + "</code></pre>\n"
            cmark_node_set_literal(html, markup)
            if cmark_node_replace(block, html) == 1 { cmark_node_free(block) } else { cmark_node_free(html) }
        }
    }

    /// Fence words people write, as the file name the editor would know them by.
    private static let aliases: [String: String] = [
        "js": "a.js", "javascript": "a.js", "node": "a.js", "mjs": "a.js", "jsx": "a.jsx",
        "ts": "a.ts", "typescript": "a.ts", "tsx": "a.tsx",
        "py": "a.py", "python": "a.py", "python3": "a.py", "rb": "a.rb", "ruby": "a.rb",
        "rs": "a.rs", "rust": "a.rs", "golang": "a.go", "kt": "a.kt", "kotlin": "a.kt", "kts": "a.kts",
        "c++": "a.cpp", "cs": "a.cs", "csharp": "a.cs", "c#": "a.cs",
        "objc": "a.m", "objective-c": "a.m", "objectivec": "a.m",
        "sh": "a.sh", "bash": "a.sh", "shell": "a.sh", "zsh": "a.sh", "fish": "a.sh", "console": "a.sh",
        "shellsession": "a.sh", "terminal": "a.sh",
        "yml": "a.yml", "yaml": "a.yml", "jsonc": "a.json", "json5": "a.json", "scss": "a.css",
        "ex": "a.ex", "elixir": "a.ex", "hs": "a.hs", "haskell": "a.hs", "ocaml": "a.ml",
        "dockerfile": "Dockerfile", "docker": "Dockerfile",
    ]

    private static func language(for word: String) -> CodeLanguage? {
        let name = aliases[word] ?? "a.\(word)"
        let language = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: name))
        // Markdown inside Markdown would colour as Markdown's syntax; plain is clearer.
        guard language.id != .plainText, language.id != .markdown, language.id != .markdownInline else { return nil }
        return language
    }

    /// The highlighted HTML of `code`, or nil when the language has no grammar or query to give it.
    private static func highlight(_ code: String, in language: CodeLanguage) -> String? {
        guard let grammar = language.language, let query = queries.query(for: language) else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(grammar)) != nil, let tree = parser.parse(code) else { return nil }

        // CodeEditSourceEditor's own resolution (`TreeSitterClient.quickHighlight`): captures in
        // reverse, a lower-indexed capture of a range winning over a higher one, later ones painting
        // over earlier ones where they overlap.
        let ns = code as NSString
        var classes = [CaptureBucket?](repeating: nil, count: ns.length)
        var levels: [NSRange: Int] = [:]
        for capture in query.execute(in: tree).resolve(with: .init(string: code)).flatMap({ $0.captures }).reversed() {
            let range = capture.range
            if let level = levels[range], level <= capture.index { continue }
            guard let name = CaptureName.fromString(capture.name) else { continue }
            levels[range] = capture.index
            let bucket = CaptureBucket(name)
            let lower = max(0, range.location), upper = min(ns.length, range.location + range.length)
            if lower < upper { for i in lower..<upper { classes[i] = bucket } }
        }

        var html = ""
        var start = 0
        while start < ns.length {
            var end = start + 1
            while end < ns.length, classes[end] == classes[start] { end += 1 }
            let text = GitHubHTMLDocument.escape(ns.substring(with: NSRange(location: start, length: end - start)))
            if let bucket = classes[start] { html += "<span class=\"hl-\(bucket.rawValue)\">\(text)</span>" } else { html += text }
            start = end
        }
        return html
    }

    /// Loaded once per language, off the main actor. `TreeSitterModel.shared` would do this too, but
    /// its queries are lazy properties the editor initialises on the main thread, and the preview
    /// renders on another one.
    private static let queries = QueryCache()

    private final class QueryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded: [String: Query?] = [:]

        func query(for language: CodeLanguage) -> Query? {
            lock.lock(); defer { lock.unlock() }
            if let cached = loaded[language.id.rawValue] { return cached }
            let query = Self.load(language)
            loaded[language.id.rawValue] = query
            return query
        }

        /// `TreeSitterModel.queryFor`: a language's highlights, with its parent's (TSX on TypeScript)
        /// or its extra files (JSX's) joined on.
        private static func load(_ language: CodeLanguage) -> Query? {
            guard let grammar = language.language, let url = language.queryURL else { return nil }
            var urls = [url]
            if let parent = language.parentQueryURL {
                urls.append(parent)
            } else if let extra = language.additionalHighlights {
                urls = extra.map { url.deletingLastPathComponent().appendingPathComponent("\($0).scm") } + urls
            }
            let source = urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
            guard let data = source.data(using: .utf8), !data.isEmpty else { return nil }
            return try? Query(language: grammar, data: data)
        }
    }
}

/// The editor theme's colour buckets, which `EditorTheme` maps captures onto privately; this is the
/// same table, so the preview's classes and the editor's colours agree.
enum CaptureBucket: String, CaseIterable {
    case keyword, comment, variable, number, string, type, attribute

    init?(_ capture: CaptureName) {
        switch capture {
        case .include, .constructor, .keyword, .boolean, .variableBuiltin, .keywordReturn, .keywordFunction,
             .repeat, .conditional, .tag: self = .keyword
        case .comment: self = .comment
        case .variable, .property, .function, .method, .parameter: self = .variable
        case .number, .float: self = .number
        case .string: self = .string
        case .type: self = .type
        case .typeAlternate: self = .attribute
        }
    }

    @MainActor
    func attribute(in theme: EditorTheme) -> EditorTheme.Attribute {
        switch self {
        case .keyword: theme.keywords
        case .comment: theme.comments
        case .variable: theme.variables
        case .number: theme.numbers
        case .string: theme.strings
        case .type: theme.types
        case .attribute: theme.attributes
        }
    }

    /// The page's rules for these classes, in the editor's current colours.
    @MainActor
    static func css(for theme: EditorTheme) -> String {
        allCases.map { bucket in
            let a = bucket.attribute(in: theme)
            let c = a.color.usingColorSpace(.sRGB) ?? a.color
            let hex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            return ".hl-\(bucket.rawValue) { color: \(hex);\(a.bold ? " font-weight: 600;" : "")\(a.italic ? " font-style: italic;" : "") }"
        }.joined(separator: "\n")
    }
}

