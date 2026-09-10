import Foundation
import Testing
@testable import ClinicCore

/// ADR-100: the diff body is a text view, so the document is where line ↔ row mapping lives.
/// ADR-101: one file at a time, so a file header is no longer part of the text.
@Suite struct DiffDocumentTests {
    static func page(hunks: Int = 1, linesPerHunk: Int = 4, width: Int = 20) -> DiffPage {
        DiffPage.build(files: [DiffRowsTests.file("f0.swift", hunks: hunks, linesPerHunk: linesPerHunk, width: width)])
    }

    @Test func oneLinePerRowAndNothingElse() {
        let page = Self.page(hunks: 2, linesPerHunk: 4)
        let doc = DiffDocument.build(page: page)
        // 2 hunk headers + 8 lines, and no header line for the file itself.
        #expect(doc.lines.count == 10)
        #expect(doc.lines.count == page.files[0].rows.count)
        #expect(doc.text.hasPrefix("@@"))
    }

    @Test func everyLineRangeAddressesItsOwnTextInTheDocument() {
        let doc = DiffDocument.build(page: Self.page())
        let ns = doc.text as NSString
        for (index, line) in doc.lines.enumerated() {
            let slice = ns.substring(with: line.range)
            #expect(!slice.contains("\n"), "line \(index) must not span a newline")
            switch line.kind {
            case .hunk: #expect(slice.hasPrefix("@@"))
            case .code: #expect(slice == String(repeating: "x", count: 20))
            }
        }
        // The document ends with a newline, so the text is exactly one line per entry.
        #expect(doc.text.filter { $0 == "\n" }.count == doc.lines.count)
    }

    @Test func everyRowIsAddressableForHighlighting() {
        let page = Self.page(hunks: 2)
        let doc = DiffDocument.build(page: page)
        let ids = doc.lines.map(\.rowId)
        #expect(ids == page.files[0].rows.map(\.id), "lines and rows agree, in order")
        #expect(Set(ids).count == ids.count, "row ids must stay unique")
    }

    @Test func lineNumbersFollowTheirRows() {
        let doc = DiffDocument.build(page: Self.page(linesPerHunk: 3))
        let code = doc.lines.filter { if case .code = $0.kind { return true } else { return false } }
        #expect(code.count == 3)
        #expect(code.allSatisfy { $0.oldNumber != nil && $0.newNumber != nil })
        // A hunk header is not a numbered line.
        #expect(doc.lines.first?.oldNumber == nil)
    }

    @Test func columnsIsTheLongestRenderedLine() {
        #expect(DiffDocument.build(page: Self.page(width: 40)).columns == 40)
    }

    @Test func anEmptyPageIsAnEmptyDocument() {
        let doc = DiffDocument.build(page: DiffPage())
        #expect(doc.isEmpty)
        #expect(doc.text.isEmpty)
        #expect(doc.columns == 0)
    }
}
