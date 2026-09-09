import Foundation
import Testing
@testable import ClinicCore

/// ADR-080: flattening and paging, the two things that keep a large diff scrollable.
@Suite struct DiffRowsTests {
    static func file(_ path: String, hunks: Int = 1, linesPerHunk: Int = 10, width: Int = 20) -> UnifiedDiffFile {
        let hunkList = (0..<hunks).map { h in
            DiffHunk(id: "\(h)", oldStart: 1, oldCount: linesPerHunk, newStart: 1, newCount: linesPerHunk,
                     lines: (0..<linesPerHunk).map { i in
                         DiffLine(id: i, kind: i % 3 == 0 ? .addition : .context,
                                  text: String(repeating: "x", count: width), oldLineNumber: i, newLineNumber: i)
                     },
                     headerText: "@@ -1,\(linesPerHunk) +1,\(linesPerHunk) @@")
        }
        return UnifiedDiffFile(oldPath: path, newPath: path, headerLines: [], hunks: hunkList)
    }

    @Test func rowsAreOnePerLinePlusOnePerHunkHeader() {
        let rows = DiffPage.rows(for: Self.file("a.swift", hunks: 2, linesPerHunk: 5), index: 3)
        #expect(rows.count == 12)
        #expect(rows.first?.id == "f3h0")
        if case .hunk = rows[0].kind {} else { Issue.record("first row should be a hunk header") }
        if case .line = rows[1].kind {} else { Issue.record("second row should be a line") }
        #expect(rows.allSatisfy { DiffPage.fileIndex(ofRowId: $0.id) == 3 })
        #expect(Set(rows.map(\.id)).count == rows.count, "row ids must be unique")
    }

    @Test func fileIndexIsRecoverableFromARowId() {
        #expect(DiffPage.fileIndex(ofRowId: "f12h3l4") == 12)
        #expect(DiffPage.fileIndex(ofRowId: "f0h0") == 0)
        #expect(DiffPage.fileIndex(ofRowId: "nonsense") == nil)
    }

    @Test func aSmallDiffIsNotPaged() {
        let files = (0..<3).map { Self.file("f\($0).swift", linesPerHunk: 10) }
        let limit = DiffPage.fileLimit(for: files)
        #expect(limit == 3)
        let page = DiffPage.build(files: files, limit: limit)
        #expect(page.files.count == 3)
        #expect(!page.hasMore && page.remainingFiles == 0)
        #expect(page.totalFiles == 3 && page.totalRows == 33)
        #expect(page.columns == 20)
    }

    @Test func theLimitStopsAtTheBudgetAndKeepsFilesWhole() {
        let files = (0..<10).map { Self.file("f\($0).swift", linesPerHunk: 100) }
        // 101 rows per file: two fit, the third would exceed 250.
        #expect(DiffPage.fileLimit(for: files, budget: 250) == 2)
        let page = DiffPage.build(files: files, limit: 2)
        #expect(page.files.map(\.file.path) == ["f0.swift", "f1.swift"], "the page is a prefix, never a subset")
        #expect(page.remainingFiles == 8)
        #expect(page.totalFiles == 10 && page.totalRows == 1010, "totals describe the whole diff, not the page")
    }

    @Test func oneEnormousFileStillRenders() {
        let files = [Self.file("huge.swift", linesPerHunk: 50_000)]
        #expect(DiffPage.fileLimit(for: files, budget: 100) == 1, "at least one file always comes in")
        let page = DiffPage.build(files: files, limit: 0)
        #expect(page.files.count == 1, "a zero limit still renders one file rather than nothing")
        #expect(!page.hasMore)
    }

    @Test func showingMoreExtendsFromWhereThePageStopped() {
        let files = (0..<10).map { Self.file("f\($0).swift", linesPerHunk: 100) }
        let first = DiffPage.fileLimit(for: files, budget: 250)
        let next = first + DiffPage.fileLimit(for: files, budget: 250, from: first)
        #expect(next > first)
        let a = DiffPage.build(files: files, limit: first)
        let b = DiffPage.build(files: files, limit: next)
        #expect(b.files.prefix(a.files.count).map(\.file.path) == a.files.map(\.file.path),
                "showing more must not reshuffle what was already on screen")
    }

    /// The rule that made collapsing slow: it used to free budget and pull unrelated files in.
    @Test func collapsingChangesCostButNotWhichFilesAreShown() {
        let files = (0..<10).map { Self.file("f\($0).swift", linesPerHunk: 100) }
        let open = DiffPage.build(files: files, limit: 3)
        let collapsed = DiffPage.build(files: files, collapsed: ["f0.swift", "f1.swift"], limit: 3)
        #expect(collapsed.files.map(\.file.path) == open.files.map(\.file.path),
                "collapsing must never add or remove files from the page")
        #expect(collapsed.files[0].rows.isEmpty && collapsed.files[1].rows.isEmpty)
        #expect(collapsed.files[2].rows.count == open.files[2].rows.count)
        // The freed budget is only spent when the reader asks for more.
        #expect(DiffPage.fileLimit(for: files, collapsed: ["f0.swift", "f1.swift"], budget: 250)
                > DiffPage.fileLimit(for: files, budget: 250))
    }

    @Test func theRowCacheReturnsIdenticalRows() {
        let files = (0..<4).map { Self.file("f\($0).swift", linesPerHunk: 40) }
        let cache = DiffPage.RowCache()
        let cold = DiffPage.build(files: files, limit: 4, rowCache: cache)
        let warm = DiffPage.build(files: files, limit: 4, rowCache: cache)
        #expect(cold == warm)
        // Collapsing and reopening goes through the cache and still matches an uncached build.
        let reopened = DiffPage.build(files: files, limit: 4, rowCache: cache)
        #expect(reopened == DiffPage.build(files: files, limit: 4))
    }

    @Test func fileSummariesAreSmallAndCarryTheCounts() {
        let file = Self.file("a/b/c.swift", linesPerHunk: 9)
        let summary = DiffFileSummary(file)
        #expect(summary.path == "a/b/c.swift" && summary.name == "c.swift")
        #expect(summary.changedLines == file.additions + file.deletions)
    }

    @Test func columnsIsTheLongestRenderedLine() {
        let page = DiffPage.build(files: [Self.file("a.swift", width: 12), Self.file("b.swift", width: 300)], limit: 2)
        #expect(page.columns == 300)
        #expect(page.files[0].columns == 12 && page.files[1].columns == 300)
    }

    @Test func anEmptyDiffPagesToNothing() {
        let page = DiffPage.build(files: [], limit: 0)
        #expect(page.files.isEmpty && !page.hasMore && page.totalRows == 0 && page.columns == 0)
    }
}
