import Foundation

/// One file's diff as text plus the metadata the view needs to draw it (ADR-100).
///
/// The diff body is an `NSTextView`, so what the view needs is not a tree of rows but a string and
/// a way to answer, for any line: what kind is it, and which row id does it carry. This type is that
/// answer, and it is Foundation-only so the mapping rules can be tested without AppKit.
///
/// **Every line is the same height in the view**, which makes line ↔ y arithmetic rather than a
/// layout query — the vertical counterpart of ADR-080's `columns × advance` content width.
public struct DiffDocument: Sendable, Equatable {
    public enum LineKind: Sendable, Equatable {
        case hunk
        case code(DiffLine.Kind)
    }

    public struct Line: Sendable, Equatable {
        public let kind: LineKind
        /// The `DiffRow` id this line was built from, which is how highlighting addresses it.
        public let rowId: String
        public let oldNumber: Int?
        public let newNumber: Int?
        /// The line's text within `text`, excluding its newline.
        public let range: NSRange
        /// The part of a changed line that actually differs from its counterpart, in the line's own
        /// coordinates (ADR-188). nil for a line with no counterpart, or one rewritten outright.
        public var emphasis: NSRange?

        public init(kind: LineKind, rowId: String, oldNumber: Int?, newNumber: Int?, range: NSRange, emphasis: NSRange? = nil) {
            self.kind = kind
            self.rowId = rowId
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.range = range
            self.emphasis = emphasis
        }
    }

    public var text: String
    public var lines: [Line]
    /// Longest rendered line in characters, for the arithmetic content width.
    public var columns: Int

    public init(text: String = "", lines: [Line] = [], columns: Int = 0) {
        self.text = text
        self.lines = lines
        self.columns = columns
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// The first line of each run of changed lines, in order: where "next change" lands (ADR-188).
    public var changeStarts: [Int] {
        var out: [Int] = []
        var inside = false
        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .code(.addition), .code(.deletion):
                if !inside { out.append(index) }
                inside = true
            case .code(.noNewline):
                continue
            case .code(.context), .hunk:
                inside = false
            }
        }
        return out
    }

    /// The line to keep under the reader's eye when this document replaces `old` (ADR-186).
    ///
    /// Matched on the *old* side's line number. A diff that refreshes under the reader keeps its
    /// base and moves its head, so old-side numbers stay put while new-side numbers shift with every
    /// line written above. An added line has no old number: the nearest numbered line above it is
    /// found instead, and the distance to it kept.
    public func line(matching index: Int, of old: DiffDocument) -> Int? {
        guard old.lines.indices.contains(index), !lines.isEmpty else { return nil }
        var probe = index
        while probe >= 0 {
            if let number = old.lines[probe].oldNumber, let hit = lines.firstIndex(where: { $0.oldNumber == number }) {
                return min(lines.count - 1, hit + (index - probe))
            }
            probe -= 1
        }
        // Nothing above carries an old number: a new file, or the very top of one.
        if let number = old.lines[index].newNumber { return lines.firstIndex { $0.newNumber == number } }
        return nil
    }

    /// Builds the document for a page. File headers are not part of the text: one file is on screen
    /// and the viewer's own header names it (ADR-101).
    public static func build(page: DiffPage) -> DiffDocument {
        var doc = DiffDocument()
        var text = ""
        text.reserveCapacity(page.files.reduce(0) { $0 + $1.rows.count * 48 })
        var length = 0          // in UTF-16 units, which is what NSRange counts
        var columns = 0

        func append(_ raw: String, kind: LineKind, rowId: String, old: Int?, new: Int?) {
            let line = Self.displayText(raw)
            let count = (line as NSString).length
            doc.lines.append(Line(kind: kind, rowId: rowId, oldNumber: old, newNumber: new,
                                  range: NSRange(location: length, length: count)))
            text += line
            text += "\n"
            length += count + 1
            columns = max(columns, line.count)
        }

        for file in page.files {
            for row in file.rows {
                switch row.kind {
                case .hunk(let header):
                    append(header, kind: .hunk, rowId: row.id, old: nil, new: nil)
                case .line(let line):
                    append(line.text, kind: .code(line.kind), rowId: row.id,
                           old: line.oldLineNumber, new: line.newLineNumber)
                }
            }
        }
        doc.text = text
        doc.columns = columns
        var offset = 0
        for file in page.files {
            for (index, range) in Self.emphasis(in: file.rows) { doc.lines[offset + index].emphasis = range }
            offset += file.rows.count
        }
        return doc
    }

    // MARK: Display text

    /// Characters a text view breaks a line at, other than the `\n` the document puts there itself.
    /// Each has a visible stand-in of the same UTF-16 length, so a token range computed against the
    /// original text still addresses the same characters.
    private static let standIns: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{000D}": "\u{240D}",   // carriage return inside a line → ␍
        "\u{000B}": "\u{240B}",   // vertical tab → ␋
        "\u{000C}": "\u{240C}",   // form feed → ␌
        "\u{0085}": "\u{2424}",   // next line → ␤
        "\u{2028}": "\u{2424}",   // line separator → ␤
        "\u{2029}": "\u{00B6}",   // paragraph separator → ¶
        "\u{0000}": "\u{2400}",   // NUL → ␀
    ]

    /// A line as the body shows it (ADR-184). The geometry is `line n at n × lineHeight`, which holds
    /// only while one document line is one visual line; a form feed or a U+2028 inside the code makes
    /// the text view break there, and every tint and line number below it is then one line off.
    public static func displayText(_ line: String) -> String {
        guard line.unicodeScalars.contains(where: { standIns[$0] != nil }) else { return line }
        var out = String.UnicodeScalarView()
        for scalar in line.unicodeScalars { out.append(standIns[scalar] ?? scalar) }
        return String(out)
    }

    // MARK: Emphasis

    /// For each changed line with a counterpart, the range that differs from it (ADR-188), keyed by
    /// the row's index in `rows`.
    ///
    /// A run of deletions followed directly by as many additions is read as line-for-line edits, and
    /// each pair gives up its common prefix and suffix. That is not a real intra-line diff and does
    /// not try to be: it finds the one edit in a line that has one, which is the case where a red line
    /// over a green one makes the reader hunt. Unequal runs are left alone, since pairing them by
    /// position would mark differences between lines that were never versions of each other.
    static func emphasis(in rows: [DiffRow]) -> [Int: NSRange] {
        var out: [Int: NSRange] = [:]
        var removed: [Int] = []
        var added: [Int] = []

        func flush() {
            defer { removed = []; added = [] }
            guard !removed.isEmpty, removed.count == added.count else { return }
            for (r, a) in zip(removed, added) {
                guard case .line(let old) = rows[r].kind, case .line(let new) = rows[a].kind,
                      let (oldRange, newRange) = difference(old.text, new.text) else { continue }
                if oldRange.length > 0 { out[r] = oldRange }
                if newRange.length > 0 { out[a] = newRange }
            }
        }

        for (index, row) in rows.enumerated() {
            guard case .line(let line) = row.kind else { flush(); continue }
            switch line.kind {
            case .deletion:
                if !added.isEmpty { flush() }
                removed.append(index)
            case .addition:
                added.append(index)
            case .noNewline:
                continue          // annotates the line above it; it does not end a run
            case .context:
                flush()
            }
        }
        flush()
        return out
    }

    /// What is left of each line once their shared start and end are taken away, in UTF-16 units, or
    /// nil when the two have too little in common for the remainder to mean anything.
    static func difference(_ old: String, _ new: String) -> (old: NSRange, new: NSRange)? {
        guard old != new else { return nil }
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        // Indentation is shared by every line near it, so it is not evidence that two lines are versions
        // of each other. What counts is what they share beyond it.
        let indent = a.prefix(while: { $0 == " " || $0 == "\t" }).count
        let shared = max(0, prefix - min(prefix, indent)) + suffix
        let longest = max(a.count, b.count) - min(indent, min(a.count, b.count))
        guard shared >= 3, longest > 0, Double(shared) / Double(longest) >= 0.3 else { return nil }

        func range(_ characters: [Character]) -> NSRange {
            let start = characters[..<prefix].reduce(0) { $0 + $1.utf16.count }
            let length = characters[prefix..<(characters.count - suffix)].reduce(0) { $0 + $1.utf16.count }
            return NSRange(location: start, length: length)
        }
        return (range(a), range(b))
    }
}
