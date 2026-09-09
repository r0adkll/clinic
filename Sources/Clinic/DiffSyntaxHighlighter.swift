import AppKit
import CodeEditLanguages
import SwiftTreeSitter
import SwiftUI
import ClinicCore

/// Token colours for the diff, taken from the editor panel's palette so a file reads the same in
/// both panes (ADR-057, ADR-080). `Sendable` values only: the theme is read on the main actor and
/// handed to the highlighter actor.
struct DiffSyntaxTheme: Sendable, Equatable {
    var keyword = RGBA(.systemPink)
    var type = RGBA(.systemTeal)
    var function = RGBA(.systemTeal)
    var string = RGBA(.systemRed)
    var number = RGBA(.systemOrange)
    var comment = RGBA(.systemGray)
    var variable = RGBA(.systemBlue)
    var constant = RGBA(.systemPurple)

    struct RGBA: Sendable, Equatable {
        var r: CGFloat, g: CGFloat, b: CGFloat
        init(_ color: NSColor) {
            let c = color.usingColorSpace(.sRGB) ?? .textColor
            r = c.redComponent; g = c.greenComponent; b = c.blueComponent
        }
        var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    }

    /// Built from the same hex pairs `EditorThemes` uses, resolved through the current appearance.
    @MainActor
    static var current: DiffSyntaxTheme {
        let appearance = NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        func c(_ light: String, _ darkHex: String) -> RGBA { RGBA(NSColor(hex: dark ? darkHex : light)) }
        return DiffSyntaxTheme(
            keyword: c("#9B2393", "#FC5FA3"),
            type: c("#0B4F79", "#5DD8FF"),
            function: c("#326D74", "#67B7A4"),
            string: c("#C41A16", "#FC6A5D"),
            number: c("#1C00CF", "#D0BF69"),
            comment: c("#5D6C79", "#6C7986"),
            variable: c("#3E8087", "#41A1C0"),
            constant: c("#6C36A9", "#A167E6")
        )
    }

    /// tree-sitter capture names are dotted and language-specific (`keyword.function`,
    /// `string.special`, …); the first component that matches decides the colour.
    func colour(forCapture name: String) -> RGBA? {
        for component in name.split(separator: ".").map(String.init) {
            switch component {
            case "keyword", "conditional", "repeat", "include", "operator": return keyword
            case "type", "class", "struct", "enum", "namespace": return type
            case "function", "method", "constructor": return function
            case "string", "character": return string
            case "number", "float", "boolean": return number
            case "comment": return comment
            case "variable", "parameter", "property", "field": return variable
            case "constant", "attribute", "annotation": return constant
            default: continue
            }
        }
        return nil
    }
}

/// Syntax-highlights a diff with tree-sitter (ADR-080).
///
/// A hunk is not a file, so each side of a hunk is parsed as its own snippet: the new side (context
/// plus additions) and the old side (context plus deletions). tree-sitter is error tolerant, so a
/// fragment still yields the captures that matter for reading a diff — keywords, strings, comments,
/// types — without fetching and parsing both whole files for every hunk.
actor DiffSyntaxHighlighter {
    /// Compiling a highlights query is the expensive part, so one per language is kept for the life
    /// of the app; parsers are cheap and made per call.
    private var queries: [String: Query] = [:]
    private var unsupported: Set<String> = []

    /// Attributed text for the line rows of `files`, keyed by row id. Rows with no language, or no
    /// captures, are simply absent and render as plain text.
    ///
    /// Cancellation is checked per file, not just on return: a superseded pass that runs to
    /// completion still holds this actor, and a dozen of them queued behind each other turned a
    /// 1.5 s highlight into 15 s of pegged CPU.
    func highlights(for files: [DiffFileRows], theme: DiffSyntaxTheme) async -> [String: AttributedString] {
        var out: [String: AttributedString] = [:]
        for file in files {
            if Task.isCancelled { return out }
            guard let grammar = grammar(for: file.file.path) else { continue }
            for (_, rows) in Self.sides(of: file) where !rows.isEmpty {
                merge(&out, snippet: rows, query: grammar.query, language: grammar.language, theme: theme)
            }
            await Task.yield()   // a 40-file page must not hold the actor for its whole duration
        }
        return out
    }

    /// The two snippets a hunk contributes: (row id, line text) in source order for each side.
    private static func sides(of file: DiffFileRows) -> [(String, [(String, String)])] {
        var newSide: [(String, String)] = []
        var oldSide: [(String, String)] = []
        for row in file.rows {
            guard case .line(let line) = row.kind else { continue }
            switch line.kind {
            case .addition: newSide.append((row.id, line.text))
            case .deletion: oldSide.append((row.id, line.text))
            case .context: newSide.append((row.id, line.text)); oldSide.append((row.id, line.text))
            case .noNewline: break
            }
        }
        return [("new", newSide), ("old", oldSide)]
    }

    private func merge(_ out: inout [String: AttributedString], snippet rows: [(String, String)],
                       query: Query, language: Language, theme: DiffSyntaxTheme) {
        // One text for the whole side, remembering where each row starts so captures map back.
        var text = ""
        var spans: [(id: String, range: NSRange)] = []
        for (id, line) in rows {
            let start = (text as NSString).length
            text += line + "\n"
            spans.append((id, NSRange(location: start, length: (line as NSString).length)))
        }
        guard !text.isEmpty else { return }

        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil, let tree = parser.parse(text), let root = tree.rootNode else { return }

        // Capture ranges, flattened; later captures win, which matches tree-sitter's own precedence.
        var captures: [(NSRange, DiffSyntaxTheme.RGBA)] = []
        for match in query.execute(node: root, in: tree) {
            for capture in match.captures {
                guard let name = capture.name, let colour = theme.colour(forCapture: name) else { continue }
                captures.append((capture.range, colour))
            }
        }
        guard !captures.isEmpty else { return }

        // Bucket captures into their lines in one pass. Filtering the whole capture list per line
        // is O(lines x captures) — on an 1,800-line file that is tens of millions of comparisons.
        captures.sort { $0.0.location < $1.0.location }
        var buckets = [[(NSRange, DiffSyntaxTheme.RGBA)]](repeating: [], count: spans.count)
        var cursor = 0
        for (index, span) in spans.enumerated() {
            // Captures ending before this line begins are behind us for good.
            while cursor < captures.count && NSMaxRange(captures[cursor].0) <= span.range.location { cursor += 1 }
            var probe = cursor
            while probe < captures.count && captures[probe].0.location < NSMaxRange(span.range) {
                let clipped = NSIntersectionRange(captures[probe].0, span.range)
                if clipped.length > 0 { buckets[index].append((clipped, captures[probe].1)) }
                probe += 1
            }
        }

        let ns = text as NSString
        for (index, span) in spans.enumerated() {
            let overlapping = buckets[index]
            guard !overlapping.isEmpty else { continue }
            let lineText = ns.substring(with: span.range)
            let attributed = NSMutableAttributedString(string: lineText)
            for (clipped, colour) in overlapping {
                let local = NSRange(location: clipped.location - span.range.location, length: clipped.length)
                guard local.location >= 0, NSMaxRange(local) <= attributed.length else { continue }
                attributed.addAttribute(.foregroundColor, value: colour.nsColor, range: local)
            }
            // Context lines are in both snippets; whichever ran last wins, and they agree.
            out[span.id] = AttributedString(attributed)
        }
    }

    private struct Grammar { var language: Language; var query: Query }

    /// Language plus compiled highlights query for a path, cached. A language Clinic has no grammar
    /// or query for is remembered as unsupported so its files are not probed again.
    private func grammar(for path: String) -> Grammar? {
        let code = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: path))
        let key = code.tsName
        guard !unsupported.contains(key) else { return nil }
        guard let language = code.language, let queryURL = code.queryURL else {
            unsupported.insert(key)
            return nil
        }
        if let cached = queries[key] { return Grammar(language: language, query: cached) }
        guard let query = try? language.query(contentsOf: queryURL) else {
            unsupported.insert(key)
            return nil
        }
        queries[key] = query
        return Grammar(language: language, query: query)
    }
}
