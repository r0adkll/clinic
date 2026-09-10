import Foundation

/// A rendered page as one text document plus the metadata a view needs to draw and address it
/// (ADR-100).
///
/// The diff body is an `NSTextView`, so what the view needs is not a tree of rows but a string and
/// a way to answer, for any line: what kind is it, which file does it belong to, and which row id
/// does it carry. This type is that answer, and it is Foundation-only so the mapping rules can be
/// tested without AppKit.
///
/// **Every line is the same height in the view**, which makes line ↔ y arithmetic rather than a
/// layout query — the vertical counterpart of ADR-080's `columns × advance` content width.
public struct DiffDocument: Sendable, Equatable {
    public enum LineKind: Sendable, Equatable {
        /// The `path  +n −n` line that opens a file.
        case fileHeader
        case hunk
        case code(DiffLine.Kind)
    }

    public struct Line: Sendable, Equatable {
        public let kind: LineKind
        public let fileIndex: Int
        /// The `DiffRow` id this line was built from; nil for a file header, which is not a row.
        public let rowId: String?
        public let oldNumber: Int?
        public let newNumber: Int?
        /// The line's text within `text`, excluding its newline.
        public let range: NSRange

        public init(kind: LineKind, fileIndex: Int, rowId: String?, oldNumber: Int?, newNumber: Int?, range: NSRange) {
            self.kind = kind
            self.fileIndex = fileIndex
            self.rowId = rowId
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.range = range
        }
    }

    public struct File: Sendable, Equatable {
        public let path: String
        public let index: Int
        /// Line number of the file's header line.
        public let headerLine: Int
        /// Header plus body, so `headerLine ..< headerLine + lineCount` is the whole file.
        public let lineCount: Int
        public let additions: Int
        public let deletions: Int
        public let isCollapsed: Bool
    }

    public var text: String
    public var lines: [Line]
    public var files: [File]
    /// Longest rendered line in characters, for the arithmetic content width.
    public var columns: Int

    public init(text: String = "", lines: [Line] = [], files: [File] = [], columns: Int = 0) {
        self.text = text
        self.lines = lines
        self.files = files
        self.columns = columns
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// Builds the document for a page. A collapsed file contributes its header line and nothing else.
    public static func build(page: DiffPage,
                             headerText: (UnifiedDiffFile, Bool) -> String = DiffDocument.header) -> DiffDocument {
        var doc = DiffDocument()
        var text = ""
        text.reserveCapacity(page.files.reduce(0) { $0 + $1.rows.count * 48 })
        var length = 0          // in UTF-16 units, which is what NSRange counts
        var columns = 0

        func append(_ line: String, kind: LineKind, file: Int, rowId: String?, old: Int?, new: Int?) {
            let count = (line as NSString).length
            doc.lines.append(Line(kind: kind, fileIndex: file, rowId: rowId, oldNumber: old, newNumber: new,
                                  range: NSRange(location: length, length: count)))
            text += line
            text += "\n"
            length += count + 1
            columns = max(columns, line.count)
        }

        for file in page.files {
            let headerLine = doc.lines.count
            let collapsed = file.rows.isEmpty
            append(headerText(file.file, collapsed), kind: .fileHeader, file: file.index, rowId: nil, old: nil, new: nil)
            for row in file.rows {
                switch row.kind {
                case .hunk(let header):
                    append(header, kind: .hunk, file: file.index, rowId: row.id, old: nil, new: nil)
                case .line(let line):
                    append(line.text, kind: .code(line.kind), file: file.index, rowId: row.id,
                           old: line.oldLineNumber, new: line.newLineNumber)
                }
            }
            doc.files.append(File(path: file.path, index: file.index, headerLine: headerLine,
                                  lineCount: doc.lines.count - headerLine,
                                  additions: file.file.additions, deletions: file.file.deletions,
                                  isCollapsed: file.rows.isEmpty))
        }
        doc.text = text
        doc.columns = columns
        return doc
    }

    /// `▾ path  +n −n`, the header line as it is drawn in the text. The marker is part of the text
    /// because the header is a line of the document, not a control: it is the only thing that says a
    /// header can be clicked, and which way it will go.
    public static func header(_ file: UnifiedDiffFile, collapsed: Bool = false) -> String {
        var parts = [file.path]
        if file.isNew { parts.append("(new)") }
        else if file.isDeleted { parts.append("(deleted)") }
        else if let old = file.oldPath, let new = file.newPath, old != new { parts.append("(renamed)") }
        parts.append("+\(file.additions)")
        parts.append("−\(file.deletions)")
        return (collapsed ? "▸ " : "▾ ") + parts.joined(separator: "  ")
    }

    /// The file a line belongs to, by binary search over the file ranges.
    public func fileIndex(atLine line: Int) -> Int? {
        guard line >= 0, !files.isEmpty else { return nil }
        var lo = 0, hi = files.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if files[mid].headerLine <= line { lo = mid } else { hi = mid - 1 }
        }
        let candidate = files[lo]
        guard line < candidate.headerLine + candidate.lineCount else { return nil }
        return lo
    }

    public func file(atLine line: Int) -> File? {
        guard let index = fileIndex(atLine: line) else { return nil }
        return files[index]
    }

    public func file(path: String) -> File? { files.first { $0.path == path } }

    /// True when the line opens a file — the click target for collapsing it.
    public func isHeader(line: Int) -> Bool {
        guard line >= 0, line < lines.count else { return false }
        return lines[line].kind == .fileHeader
    }

    /// Line numbers for the rows named, so highlighting can be applied by row id.
    public func lineIndexByRowId() -> [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if let id = line.rowId { out[id] = index }
        }
        return out
    }
}
