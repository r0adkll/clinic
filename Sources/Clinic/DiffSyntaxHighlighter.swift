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

/// Syntax-highlights a diff with tree-sitter (ADR-080, ADR-186).
///
/// Where the file's own text can be had — a diff between two trees Clinic can read — each side is
/// parsed **whole** and its colours mapped onto the diff by line number. That is the only parse that
/// is right: a hunk that opens inside a string or a block comment has no way to know it.
///
/// Where it cannot (a pull request's diff, a file too large to be worth it), each side of each hunk
/// is parsed as its own snippet: the new side (context plus additions) and the old side (context
/// plus deletions). tree-sitter is error tolerant, so a fragment still yields the captures that
/// matter for reading a diff. One snippet per hunk, never the hunks joined: lines that are not
/// neighbours in the file are not neighbours to a parser either, and an unbalanced hunk used to
/// mis-colour every hunk after it.
actor DiffSyntaxHighlighter {
    /// Compiling a highlights query is the expensive part, so one per language is kept for the life
    /// of the app; parsers are cheap and made per call.
    private var queries: [String: Query] = [:]
    private var unsupported: Set<String> = []

    /// Coloured ranges for the line rows of `file`, keyed by row id, in each row's own coordinates.
    /// Rows with no language, or no captures, are simply absent and render plain.
    ///
    /// `new` and `old` are the file's text on each side, when the caller could read them.
    func highlights(for file: DiffFileRows, new: String? = nil, old: String? = nil, theme: DiffSyntaxTheme) async -> [String: [DiffToken]] {
        guard let grammar = grammar(for: file.file.path) else { return [:] }
        var out: [String: [DiffToken]] = [:]
        // Old side first: a context line is on both sides, and where the two disagree — the same
        // text inside a comment before and outside it after — the new side is the one being read.
        for side in [Side.old, .new] {
            if Task.isCancelled { return out }
            if let text = side == .new ? new : old {
                wholeFile(&out, text: text, rows: file.rows, side: side, grammar: grammar, theme: theme)
            } else {
                for snippet in Self.snippets(of: file, side: side) where !snippet.isEmpty {
                    merge(&out, snippet: snippet, query: grammar.query, language: grammar.language, theme: theme)
                }
            }
            await Task.yield()
        }
        return out
    }

    private enum Side { case old, new }

    /// Parses one side's whole text and hands each diff row the colours of the file line it shows.
    private func wholeFile(_ out: inout [String: [DiffToken]], text: String, rows: [DiffRow], side: Side,
                           grammar: Grammar, theme: DiffSyntaxTheme) {
        // One entry per file line, keyed by its 1-based number.
        var lines: [(String, String)] = []
        var number = 1
        for line in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append((String(number), String(Substring(line))))
            number += 1
        }
        var byLine: [String: [DiffToken]] = [:]
        merge(&byLine, snippet: lines, query: grammar.query, language: grammar.language, theme: theme)
        guard !byLine.isEmpty else { return }
        for row in rows {
            guard case .line(let line) = row.kind else { continue }
            let number: Int?
            switch (line.kind, side) {
            case (.addition, .new), (.context, .new): number = line.newLineNumber
            case (.deletion, .old), (.context, .old): number = line.oldLineNumber
            default: number = nil
            }
            if let number, let tokens = byLine[String(number)] { out[row.id] = tokens }
        }
    }

    /// One side's lines, hunk by hunk: (row id, line text) in source order.
    private static func snippets(of file: DiffFileRows, side: Side) -> [[(String, String)]] {
        var out: [[(String, String)]] = []
        var current: [(String, String)] = []
        for row in file.rows {
            switch row.kind {
            case .hunk:
                out.append(current)
                current = []
            case .line(let line):
                switch (line.kind, side) {
                case (.addition, .new), (.deletion, .old), (.context, _): current.append((row.id, line.text))
                default: break
                }
            }
        }
        out.append(current)
        return out
    }

    private func merge(_ out: inout [String: [DiffToken]], snippet rows: [(String, String)],
                       query: Query, language: Language, theme: DiffSyntaxTheme) {
        // One text for the whole side, remembering where each row starts so captures map back.
        var text = ""
        var spans: [(id: String, range: NSRange)] = []
        // A running offset, not `(text as NSString).length` per line: that walks the text so far each
        // time, which is quadratic once the snippet is a whole file.
        var offset = 0
        for (id, line) in rows {
            let length = line.utf16.count
            text += line
            text += "\n"
            spans.append((id, NSRange(location: offset, length: length)))
            offset += length + 1
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
        // Stable on purpose: where two captures start at the same place the later one in query order
        // must still be applied last, and `sort` alone does not promise to keep them in order.
        captures = captures.enumerated().sorted { ($0.element.0.location, $0.offset) < ($1.element.0.location, $1.offset) }.map(\.element)
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

        for (index, span) in spans.enumerated() {
            let overlapping = buckets[index]
            guard !overlapping.isEmpty else { continue }
            var tokens: [DiffToken] = []
            tokens.reserveCapacity(overlapping.count)
            for (clipped, colour) in overlapping {
                let local = NSRange(location: clipped.location - span.range.location, length: clipped.length)
                guard local.location >= 0, NSMaxRange(local) <= span.range.length else { continue }
                tokens.append(DiffToken(range: local, colour: colour))
            }
            // Context lines are in both snippets; whichever ran last wins, and they agree.
            if !tokens.isEmpty { out[span.id] = tokens }
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
