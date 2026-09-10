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

        public init(kind: LineKind, rowId: String, oldNumber: Int?, newNumber: Int?, range: NSRange) {
            self.kind = kind
            self.rowId = rowId
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.range = range
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

    /// Builds the document for a page. File headers are not part of the text: one file is on screen
    /// and the viewer's own header names it (ADR-101).
    public static func build(page: DiffPage) -> DiffDocument {
        var doc = DiffDocument()
        var text = ""
        text.reserveCapacity(page.files.reduce(0) { $0 + $1.rows.count * 48 })
        var length = 0          // in UTF-16 units, which is what NSRange counts
        var columns = 0

        func append(_ line: String, kind: LineKind, rowId: String, old: Int?, new: Int?) {
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
        return doc
    }
}
