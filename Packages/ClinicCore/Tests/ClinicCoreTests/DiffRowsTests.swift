import Foundation
import Testing
@testable import ClinicCore

/// ADR-080 flattened a diff into rows; ADR-101 removed the paging that used to sit on top of them,
/// because the panel now renders one file at a time.
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
        #expect(Set(rows.map(\.id)).count == rows.count, "row ids must be unique")
    }

    @Test func aFileFlattensToRowsWithItsLongestLine() {
        let page = DiffPage.build(files: [Self.file("a.swift", hunks: 2, linesPerHunk: 5, width: 12)])
        #expect(page.files.count == 1)
        #expect(page.files[0].rows.count == 12)
        #expect(page.files[0].columns == 12 && page.columns == 12)
        #expect(page.files[0].changedLines == page.files[0].file.additions + page.files[0].file.deletions)
    }

    @Test func oneEnormousFileStillRenders() {
        let page = DiffPage.build(files: [Self.file("huge.swift", linesPerHunk: 50_000)])
        #expect(page.files.count == 1)
        #expect(page.files[0].rows.count == 50_001)
    }

    @Test func columnsIsTheLongestRenderedLine() {
        let page = DiffPage.build(files: [Self.file("a.swift", width: 12), Self.file("b.swift", width: 300)])
        #expect(page.columns == 300)
        #expect(page.files[0].columns == 12 && page.files[1].columns == 300)
    }

    @Test func anEmptyDiffBuildsNothing() {
        let page = DiffPage.build(files: [])
        #expect(page.files.isEmpty && page.columns == 0)
    }
}
