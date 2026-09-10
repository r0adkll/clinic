import Foundation

/// A diff flattened into one row per rendered line (ADR-080).
///
/// Rows are what the highlighter parses and what `DiffDocument` turns into text; the body itself is
/// a text view (ADR-100), not a view per row.
public struct DiffRow: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case hunk(header: String)
        case line(DiffLine)
    }

    /// `f<file>h<hunk>l<line>`, unique within a diff.
    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// One file's header plus its flattened rows, ready to render.
public struct DiffFileRows: Identifiable, Sendable, Equatable {
    public let index: Int
    public let file: UnifiedDiffFile
    public let rows: [DiffRow]
    /// Longest rendered line in characters, for the shared content width.
    public let columns: Int

    public var id: String { file.path }
    public var path: String { file.path }
    public var changedLines: Int { file.additions + file.deletions }
}

/// Files flattened into rows, ready to render (ADR-080).
///
/// It used to carry a whole scope and page it against a 20,000-row budget, because the panel
/// rendered every file at once. The panel now shows one file at a time ([[ADR-101]]), so the budget,
/// the "show more" bookkeeping and the row cache are gone: what is left is the flattening.
public struct DiffPage: Sendable, Equatable {
    /// The files that are rendered, in order.
    public var files: [DiffFileRows]
    /// Longest line across the rendered files, in characters.
    public var columns: Int

    public init(files: [DiffFileRows] = [], columns: Int = 0) {
        self.files = files
        self.columns = columns
    }

    /// Flattens `files` into rows, longest line included.
    public static func build(files: [UnifiedDiffFile]) -> DiffPage {
        var page = DiffPage()
        for (index, file) in files.enumerated() {
            let rows = Self.rows(for: file, index: index)
            let columns = rows.reduce(0) { longest, row in
                if case .line(let line) = row.kind { return max(longest, line.text.count) }
                return longest
            }
            page.files.append(DiffFileRows(index: index, file: file, rows: rows, columns: columns))
            page.columns = max(page.columns, columns)
        }
        return page
    }

    public static func rows(for file: UnifiedDiffFile, index: Int) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(file.hunks.reduce(0) { $0 + $1.lines.count + 1 })
        for (h, hunk) in file.hunks.enumerated() {
            rows.append(DiffRow(id: "f\(index)h\(h)", kind: .hunk(header: hunk.headerText)))
            for line in hunk.lines {
                rows.append(DiffRow(id: "f\(index)h\(h)l\(line.id)", kind: .line(line)))
            }
        }
        return rows
    }
}
