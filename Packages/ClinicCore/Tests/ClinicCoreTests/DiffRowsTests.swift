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
        let page = DiffPage.build(files: files)
        #expect(page.files.count == 3)
        #expect(!page.hasMore && page.remainingFiles == 0)
        #expect(page.totalFiles == 3)
        #expect(page.totalRows == 33)
        #expect(page.columns == 20)
    }

    @Test func pagingStopsAtTheBudgetAndKeepsFilesWhole() {
        let files = (0..<10).map { Self.file("f\($0).swift", linesPerHunk: 100) }
        let page = DiffPage.build(files: files, budget: 250)
        // 101 rows per file: two fit, the third would exceed 250.
        #expect(page.files.count == 2)
        #expect(page.remainingFiles == 8)
        #expect(page.files.map(\.file.path) == ["f0.swift", "f1.swift"], "the page is a prefix, never a subset")
        #expect(page.totalFiles == 10 && page.totalRows == 1010, "totals describe the whole diff, not the page")
    }

    @Test func oneEnormousFileStillRenders() {
        let page = DiffPage.build(files: [Self.file("huge.swift", linesPerHunk: 50_000)], budget: 100)
        #expect(page.files.count == 1, "the first file always comes in, or the panel would show nothing")
        #expect(!page.hasMore)
    }

    @Test func raisingTheBudgetExtendsThePage() {
        let files = (0..<10).map { Self.file("f\($0).swift", linesPerHunk: 100) }
        let first = DiffPage.build(files: files, budget: 250)
        let second = DiffPage.build(files: files, budget: 500)
        #expect(second.files.count > first.files.count)
        #expect(second.files.prefix(first.files.count).map(\.file.path) == first.files.map(\.file.path),
                "showing more must not reshuffle what was already on screen")
    }

    @Test func collapsingAFileFreesItsWholeBudget() {
        let files = (0..<10).map { Self.file("f\($0).swift", linesPerHunk: 100) }
        let open = DiffPage.build(files: files, budget: 250)
        let collapsed = DiffPage.build(files: files, collapsed: ["f0.swift", "f1.swift"], budget: 250)
        #expect(collapsed.files.count > open.files.count, "a collapsed file costs no lines")
        #expect(collapsed.files.first?.rows.isEmpty == true)
        #expect(collapsed.files.first?.file.path == "f0.swift", "a collapsed file is still listed")
    }

    @Test func columnsIsTheLongestRenderedLine() {
        let page = DiffPage.build(files: [Self.file("a.swift", width: 12), Self.file("b.swift", width: 300)])
        #expect(page.columns == 300)
        #expect(page.files[0].columns == 12 && page.files[1].columns == 300)
    }

    @Test func anEmptyDiffPagesToNothing() {
        let page = DiffPage.build(files: [])
        #expect(page.files.isEmpty && !page.hasMore && page.totalRows == 0 && page.columns == 0)
    }
}
