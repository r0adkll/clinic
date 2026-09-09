import Foundation

/// What a run of markdown text is, for colouring purposes (ADR-081).
public enum MarkdownSpanKind: Sendable, Hashable {
    case heading        // a whole `#` or setext heading line, markers included
    case strong         // **bold**, __bold__
    case emphasis       // *italic*, _italic_
    case code           // `inline code`
    case codeBlock      // a fenced block, fences included
    case linkText       // the [text] of a link or image
    case url            // the (destination), an <autolink>, or a bare URL
    case quote          // a `>` line
    case marker         // list bullets, numbers, table pipes, thematic breaks
    case comment        // HTML comments and YAML front matter
}

public struct MarkdownSpan: Sendable, Hashable {
    public let range: NSRange
    public let kind: MarkdownSpanKind

    public init(range: NSRange, kind: MarkdownSpanKind) {
        self.range = range
        self.kind = kind
    }
}

/// A small line-based markdown scanner.
///
/// It exists because the tree-sitter markdown grammar's captures (`text.title`, `text.literal`,
/// `punctuation.special`, …) are not in CodeEditSourceEditor's `CaptureName`, so every one of them
/// resolves to nil and a markdown file renders as plain text however good the parse was (ADR-081).
/// This is deliberately a scanner and not a parser: it colours what a reader looks for — headings,
/// code, links, quotes, lists — and never tries to be CommonMark.
public enum MarkdownSyntax {
    /// Scans the whole document. Callers filter to the range they are drawing; block state (a fenced
    /// block, front matter) reaches back to the top of the file, so a partial scan would be wrong.
    public static func spans(in text: String) -> [MarkdownSpan] {
        let ns = text as NSString
        var spans: [MarkdownSpan] = []
        var fence: String?            // the delimiter that opened the current block, if any
        var inFrontMatter = false
        var lineIndex = 0

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, range, _, _ in
            defer { lineIndex += 1 }
            guard let line else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // YAML front matter: only when `---` is the very first line.
            if lineIndex == 0, trimmed == "---" {
                inFrontMatter = true
                spans.append(MarkdownSpan(range: range, kind: .comment))
                return
            }
            if inFrontMatter {
                spans.append(MarkdownSpan(range: range, kind: .comment))
                if trimmed == "---" || trimmed == "..." { inFrontMatter = false }
                return
            }

            if let open = fence {
                spans.append(MarkdownSpan(range: range, kind: .codeBlock))
                if trimmed.hasPrefix(open) { fence = nil }
                return
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                spans.append(MarkdownSpan(range: range, kind: .codeBlock))
                return
            }

            if headingLevel(trimmed) > 0 {
                spans.append(MarkdownSpan(range: range, kind: .heading))
                return
            }
            if isSetextUnderline(trimmed) || isThematicBreak(trimmed) {
                spans.append(MarkdownSpan(range: range, kind: .marker))
                return
            }
            if trimmed.hasPrefix(">") {
                spans.append(MarkdownSpan(range: range, kind: .quote))
                return
            }

            var body = range
            if let marker = listMarker(line, at: range) {
                spans.append(MarkdownSpan(range: marker, kind: .marker))
                let consumed = marker.location + marker.length - range.location
                body = NSRange(location: range.location + consumed, length: range.length - consumed)
            }
            spans.append(contentsOf: inlineSpans(ns.substring(with: body), offset: body.location))
        }
        return spans
    }

    /// The spans that intersect `range`, for a view drawing only part of the document.
    public static func spans(in text: String, clippedTo range: NSRange) -> [MarkdownSpan] {
        spans(in: text).filter { NSIntersectionRange($0.range, range).length > 0 || $0.range.length == 0 }
    }

    // MARK: - Lines

    /// 1–6 `#` followed by a space or end of line; anything else is not a heading (`#hashtag` is not).
    private static func headingLevel(_ trimmed: String) -> Int {
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1; if level > 6 { return 0 } } else { break }
        }
        guard level > 0 else { return 0 }
        let rest = trimmed.dropFirst(level)
        return rest.isEmpty || rest.first == " " ? level : 0
    }

    private static func isSetextUnderline(_ trimmed: String) -> Bool {
        trimmed.count >= 3 && (trimmed.allSatisfy { $0 == "=" })
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let stripped = trimmed.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    /// The bullet or number that opens a list item, as a range in the document.
    private static func listMarker(_ line: String, at range: NSRange) -> NSRange? {
        let chars = Array(line.utf16)
        var i = 0
        while i < chars.count, chars[i] == 32 || chars[i] == 9 { i += 1 }   // space, tab
        guard i < chars.count else { return nil }
        let start = i
        let bullet = chars[i]
        if bullet == 45 || bullet == 42 || bullet == 43 {                   // - * +
            guard i + 1 < chars.count, chars[i + 1] == 32 else { return nil }
            return NSRange(location: range.location + start, length: 1)
        }
        while i < chars.count, chars[i] >= 48, chars[i] <= 57 { i += 1 }    // digits
        guard i > start, i < chars.count, chars[i] == 46 || chars[i] == 41 else { return nil }  // . )
        guard i + 1 < chars.count, chars[i + 1] == 32 else { return nil }
        return NSRange(location: range.location + start, length: i - start + 1)
    }

    // MARK: - Inline

    /// Scans one line's worth of inline markup. Backticks win over emphasis, as they do in markdown,
    /// and every span must open and close on the same line — an unclosed `*` is just an asterisk.
    private static func inlineSpans(_ line: String, offset: Int) -> [MarkdownSpan] {
        let c = Array(line.utf16)
        var spans: [MarkdownSpan] = []
        var i = 0

        func span(_ start: Int, _ end: Int, _ kind: MarkdownSpanKind) {
            spans.append(MarkdownSpan(range: NSRange(location: offset + start, length: end - start), kind: kind))
        }

        while i < c.count {
            let ch = c[i]
            switch ch {
            case 92:                                                        // backslash escape
                i += 2

            case 96:                                                        // `
                let start = i
                var run = 0
                while i < c.count, c[i] == 96 { run += 1; i += 1 }
                var j = i
                var closed = false
                while j < c.count {
                    if c[j] == 96 {
                        var k = j, closing = 0
                        while k < c.count, c[k] == 96 { closing += 1; k += 1 }
                        if closing == run { span(start, k, .code); i = k; closed = true; break }
                        j = k
                    } else {
                        j += 1
                    }
                }
                if !closed { /* an unmatched run is literal text */ }

            case 42, 95:                                                    // * _
                let start = i
                var run = 0
                while i < c.count, c[i] == ch, run < 2 { run += 1; i += 1 }
                if let close = closingRun(c, from: i, marker: ch, run: run) {
                    span(start, close + run, run == 2 ? .strong : .emphasis)
                    i = close + run
                }

            case 91, 33:                                                    // [ or ![
                let start = i
                var j = i
                if ch == 33 {
                    guard j + 1 < c.count, c[j + 1] == 91 else { i += 1; continue }
                    j += 1
                }
                guard let textEnd = index(of: 93, in: c, from: j + 1) else { i += 1; continue }   // ]
                guard textEnd + 1 < c.count, c[textEnd + 1] == 40 else { i = textEnd + 1; continue }  // (
                guard let urlEnd = index(of: 41, in: c, from: textEnd + 2) else { i = textEnd + 1; continue }  // )
                span(start, textEnd + 1, .linkText)
                span(textEnd + 1, urlEnd + 1, .url)
                i = urlEnd + 1

            case 60:                                                        // <autolink>
                if let end = index(of: 62, in: c, from: i + 1), looksLikeURL(c, from: i + 1, to: end) {
                    span(i, end + 1, .url)
                    i = end + 1
                } else if let end = htmlCommentEnd(c, from: i) {
                    span(i, end, .comment)
                    i = end
                } else {
                    i += 1
                }

            case 124:                                                       // | table cell
                span(i, i + 1, .marker)
                i += 1

            default:
                i += 1
            }
        }
        return spans
    }

    /// The index where a matching emphasis run of the same length starts, if any.
    private static func closingRun(_ c: [UInt16], from: Int, marker: UInt16, run: Int) -> Int? {
        var i = from
        guard i < c.count, c[i] != 32 else { return nil }   // `* ` opens nothing
        while i < c.count {
            if c[i] == 92 { i += 2; continue }
            if c[i] == marker {
                var k = i, len = 0
                while k < c.count, c[k] == marker { len += 1; k += 1 }
                if len >= run, c[i - 1] != 32 { return i }
                i = k
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func index(of scalar: UInt16, in c: [UInt16], from: Int) -> Int? {
        var i = from
        while i < c.count {
            if c[i] == 92 { i += 2; continue }
            if c[i] == scalar { return i }
            i += 1
        }
        return nil
    }

    private static func looksLikeURL(_ c: [UInt16], from: Int, to end: Int) -> Bool {
        let text = String(decoding: c[from..<end], as: UTF16.self)
        return text.contains("://") || text.contains("@")
    }

    /// The index just past `-->`, when an HTML comment opens here.
    private static func htmlCommentEnd(_ c: [UInt16], from: Int) -> Int? {
        let open: [UInt16] = Array("<!--".utf16), close: [UInt16] = Array("-->".utf16)
        guard from + open.count <= c.count, Array(c[from..<(from + open.count)]) == open else { return nil }
        var i = from + open.count
        while i + close.count <= c.count {
            if Array(c[i..<(i + close.count)]) == close { return i + close.count }
            i += 1
        }
        return c.count
    }
}
