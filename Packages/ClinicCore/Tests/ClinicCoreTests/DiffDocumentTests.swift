import Foundation
import Testing
@testable import ClinicCore

/// ADR-100: the diff body is a text view, so the document is where line ↔ file ↔ row mapping lives.
@Suite struct DiffDocumentTests {
    static func page(files: Int = 2, hunks: Int = 1, linesPerHunk: Int = 4, collapsed: Set<String> = []) -> DiffPage {
        let list = (0..<files).map { DiffRowsTests.file("f\($0).swift", hunks: hunks, linesPerHunk: linesPerHunk) }
        return DiffPage.build(files: list, collapsed: collapsed, limit: list.count)
    }

    @Test func oneLinePerRowPlusOneHeaderPerFile() {
        let doc = DiffDocument.build(page: Self.page(files: 2, hunks: 2, linesPerHunk: 4))
        // per file: 1 header + 2 hunk headers + 8 lines
        #expect(doc.lines.count == 2 * 11)
        #expect(doc.files.count == 2)
        #expect(doc.files[0].headerLine == 0)
        #expect(doc.files[1].headerLine == 11)
        #expect(doc.files.allSatisfy { $0.lineCount == 11 })
    }

    @Test func everyLineRangeAddressesItsOwnTextInTheDocument() {
        let doc = DiffDocument.build(page: Self.page())
        let ns = doc.text as NSString
        for (index, line) in doc.lines.enumerated() {
            let slice = ns.substring(with: line.range)
            #expect(!slice.contains("\n"), "line \(index) must not span a newline")
            switch line.kind {
            case .fileHeader: #expect(slice.hasPrefix("▾ f"))
            case .hunk: #expect(slice.hasPrefix("@@"))
            case .code: #expect(slice == String(repeating: "x", count: 20))
            }
        }
        // The document ends with a newline, so the text is exactly one line per entry.
        #expect(doc.text.filter { $0 == "\n" }.count == doc.lines.count)
    }

    @Test func aCollapsedFileIsItsHeaderAndNothingElse() {
        let doc = DiffDocument.build(page: Self.page(files: 2, collapsed: ["f0.swift"]))
        #expect(doc.files[0].lineCount == 1)
        #expect(doc.files[0].isCollapsed)
        let ns = doc.text as NSString
        #expect(ns.substring(with: doc.lines[0].range).hasPrefix("▸"), "a collapsed file says so")
        #expect(ns.substring(with: doc.lines[1].range).hasPrefix("▾"))
        #expect(doc.files[1].isCollapsed == false)
        #expect(doc.isHeader(line: 0))
        #expect(doc.isHeader(line: 1))          // the second file's header follows immediately
        #expect(doc.isHeader(line: 2) == false)
    }

    @Test func lineMapsBackToItsFile() {
        let doc = DiffDocument.build(page: Self.page(files: 3, linesPerHunk: 4))
        for (index, line) in doc.lines.enumerated() {
            #expect(doc.fileIndex(atLine: index) == line.fileIndex, "line \(index)")
        }
        #expect(doc.fileIndex(atLine: -1) == nil)
        #expect(doc.fileIndex(atLine: doc.lines.count) == nil)
        #expect(doc.file(path: "f1.swift")?.index == 1)
    }

    @Test func rowIdsAddressLinesForHighlighting() {
        let page = Self.page(files: 2)
        let doc = DiffDocument.build(page: page)
        let byRow = doc.lineIndexByRowId()
        // Headers are not rows; every row of the page is addressable exactly once.
        #expect(byRow.count == page.files.reduce(0) { $0 + $1.rows.count })
        for file in page.files {
            for row in file.rows {
                let line = try! #require(byRow[row.id])
                #expect(doc.lines[line].rowId == row.id)
                #expect(doc.lines[line].fileIndex == file.index)
            }
        }
    }

    @Test func columnsIsTheLongestRenderedLine() {
        let files = [DiffRowsTests.file("a.swift", linesPerHunk: 2, width: 12),
                     DiffRowsTests.file("b.swift", linesPerHunk: 2, width: 40)]
        let doc = DiffDocument.build(page: DiffPage.build(files: files, limit: 2))
        #expect(doc.columns >= 40)
    }

    @Test func anEmptyPageIsAnEmptyDocument() {
        let doc = DiffDocument.build(page: DiffPage())
        #expect(doc.isEmpty)
        #expect(doc.text.isEmpty)
        #expect(doc.fileIndex(atLine: 0) == nil)
    }
}
