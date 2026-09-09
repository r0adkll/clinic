import Foundation

/// A diff flattened into one row per rendered line (ADR-080).
///
/// The panel used to nest a per-file, non-lazy stack inside a horizontal scroll view, which stopped
/// `LazyVStack` from virtualising anything smaller than a whole file: one 300-line file near the
/// viewport materialised 300 rows at once. Rows are flat so laziness reaches individual lines.
public struct DiffRow: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case hunk(header: String)
        case line(DiffLine)
    }

    /// `f<file>h<hunk>l<line>` — unique within a diff, and the file index is recoverable from it,
    /// which is how the file rail knows which chip to highlight as the reader scrolls.
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

/// Flattens files into rows and decides how much of a diff is on screen at once (ADR-080).
public struct DiffPage: Sendable, Equatable {
    /// The files that are rendered, in order.
    public var files: [DiffFileRows]
    /// How many files are held back behind "Show more".
    public var remainingFiles: Int
    /// Longest line across the *rendered* files, in characters.
    public var columns: Int
    /// Total files and lines in the whole diff, rendered or not.
    public var totalFiles: Int
    public var totalRows: Int

    public var hasMore: Bool { remainingFiles > 0 }

    public init(files: [DiffFileRows] = [], remainingFiles: Int = 0, columns: Int = 0, totalFiles: Int = 0, totalRows: Int = 0) {
        self.files = files
        self.remainingFiles = remainingFiles
        self.columns = columns
        self.totalFiles = totalFiles
        self.totalRows = totalRows
    }

    /// Files come in whole — a half-rendered file reads as a truncated file, not as a page break —
    /// so the limit is a *line budget* that admits files until it is spent, always taking at least
    /// one. `collapsed` files cost only their header, which is what makes collapsing a way out of a
    /// diff too big to page through.
    public static func build(files: [UnifiedDiffFile], collapsed: Set<String> = [], budget: Int = 2000) -> DiffPage {
        var page = DiffPage(totalFiles: files.count)
        page.totalRows = files.reduce(0) { $0 + $1.hunks.reduce(0) { $0 + $1.lines.count + 1 } }
        var spent = 0
        var stopped = false
        for (index, file) in files.enumerated() {
            let rows = collapsed.contains(file.path) ? [] : Self.rows(for: file, index: index)
            // Once one file is held back every later one is too, so "Show more" extends the page
            // rather than skipping around in it.
            if stopped || (!page.files.isEmpty && spent + rows.count > budget) {
                stopped = true
                page.remainingFiles += 1
                continue
            }
            spent += rows.count
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

    /// The file index encoded in a row id, for the rail's scroll tracking.
    public static func fileIndex(ofRowId id: String) -> Int? {
        guard id.hasPrefix("f") else { return nil }
        let digits = id.dropFirst().prefix { $0.isNumber }
        return Int(digits)
    }
}
