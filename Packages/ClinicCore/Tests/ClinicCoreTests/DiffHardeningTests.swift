import Foundation
import Testing
@testable import ClinicCore

/// ADR-184: what the parser and the document have to survive that the first fixtures never held.
@Suite struct DiffHardeningTests {
    @Test func aWindowsFileParsesLineByLine() {
        let text = "diff --git a/x.bat b/x.bat\n--- a/x.bat\n+++ b/x.bat\n@@ -1,3 +1,3 @@\n one\r\n-two\r\n+TWO\r\n three\r\n"
        let file = UnifiedDiff.parse(text).files[0]
        #expect(file.hunks[0].lines.map(\.text) == ["one", "two", "TWO", "three"])
        #expect(file.additions == 1 && file.deletions == 1)
        #expect(file.hunks[0].lines.allSatisfy { $0.endsWithCarriageReturn }, "the ending is kept, off the text")
        // A patch built from it carries the endings it was read with.
        #expect(file.patchText(for: file.hunks[0]).contains("-two\r\n+TWO\r\n"))
    }

    @Test func aLineEndingConversionIsRecognised() {
        let text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-one\n-two\n+one\r\n+two\r\n"
        #expect(UnifiedDiff.parse(text).files[0].changesOnlyLineEndings)
        let edit = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-one\n+uno\n"
        #expect(!UnifiedDiff.parse(edit).files[0].changesOnlyLineEndings)
    }

    @Test func quotedPathsAreDecodedAsUTF8() {
        let text = "diff --git \"a/caf\\303\\251 \\\"x\\\".txt\" \"b/caf\\303\\251 \\\"x\\\".txt\"\n"
            + "--- \"a/caf\\303\\251 \\\"x\\\".txt\"\n+++ \"b/caf\\303\\251 \\\"x\\\".txt\"\n@@ -1 +1 @@\n-a\n+b\n"
        #expect(UnifiedDiff.parse(text).files[0].path == "café \"x\".txt")
    }

    @Test func aQuotedRenameWithNoHunksKeepsBothNames() {
        let text = "diff --git \"a/na\\303\\257ve.txt\" \"b/plain.txt\"\nsimilarity index 100%\nrename from \"na\\303\\257ve.txt\"\nrename to plain.txt\n"
        let file = UnifiedDiff.parse(text).files[0]
        #expect(file.renamedFrom == "naïve.txt" && file.newPath == "plain.txt" && file.hunks.isEmpty)
    }

    @Test func aModeChangeIsReadFromTheHeader() {
        let text = "diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n"
        let change = UnifiedDiff.parse(text).files[0].modeChange
        #expect(change?.old == "100644" && change?.new == "100755")
    }

    @Test func theContentKeyFollowsTheBlobs() {
        func file(_ index: String) -> UnifiedDiffFile {
            UnifiedDiff.parse("diff --git a/x b/x\nindex \(index) 100644\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n").files[0]
        }
        #expect(file("111..222").contentKey == file("111..222").contentKey)
        #expect(file("111..222").contentKey != file("111..333").contentKey)
    }

    // MARK: The document

    @Test func charactersThatBreakALineAreShownNotObeyed() {
        let raw = "a\u{2028}b\u{0C}c\rd\u{2029}e\u{85}f\u{0B}g"
        let shown = DiffDocument.displayText(raw)
        #expect((shown as NSString).length == (raw as NSString).length, "token ranges still address the same characters")
        #expect(shown.unicodeScalars.allSatisfy { !CharacterSet.newlines.contains($0) })
        #expect((shown as NSString).components(separatedBy: .newlines).count == 1)
        #expect(DiffDocument.displayText("plain") == "plain")
    }

    @Test func oneDocumentLineIsOneVisualLine() {
        let text = "diff --git a/y.js b/y.js\n--- a/y.js\n+++ b/y.js\n@@ -1,2 +1,2 @@\n a\u{2028}b\n-c\n+d\n"
        let doc = DiffDocument.build(page: DiffPage.build(files: UnifiedDiff.parse(text).files))
        #expect((doc.text as NSString).components(separatedBy: .newlines).count == doc.lines.count + 1)   // + the trailing newline
    }

    @Test func aOneWordEditIsEmphasisedOnBothLines() throws {
        let text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n keep\n-    let count = items.count\n+    let total = items.count\n keep\n"
        let doc = DiffDocument.build(page: DiffPage.build(files: UnifiedDiff.parse(text).files))
        let ns = doc.text as NSString
        let old = try #require(doc.lines[2].emphasis), new = try #require(doc.lines[3].emphasis)
        #expect(ns.substring(with: NSRange(location: doc.lines[2].range.location + old.location, length: old.length)) == "count")
        #expect(ns.substring(with: NSRange(location: doc.lines[3].range.location + new.location, length: new.length)) == "total")
        #expect(doc.lines[1].emphasis == nil)
    }

    @Test func rewrittenLinesAndUnequalRunsAreLeftAlone() {
        // Nothing in common beyond the indent.
        #expect(DiffDocument.difference("    return a", "    guard let x else { fatalError() }") == nil)
        // Two removed, one added: not line-for-line versions of each other.
        let text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1 @@\n-let alpha = 1\n-let beta = 2\n+let alpha = 3\n"
        let doc = DiffDocument.build(page: DiffPage.build(files: UnifiedDiff.parse(text).files))
        #expect(doc.lines.allSatisfy { $0.emphasis == nil })
    }

    @Test func emphasisCountsInUTF16() throws {
        let (old, new) = try #require(DiffDocument.difference("say(\"😀 hello\")", "say(\"😀 howdy\")"))
        #expect(("say(\"😀 hello\")" as NSString).substring(with: old) == "ello")
        #expect(("say(\"😀 howdy\")" as NSString).substring(with: new) == "owdy")
    }
}

/// ADR-186, ADR-188: what the body needs to know about a document beyond its text.
@Suite struct DiffReadingTests {
    static func document(_ text: String) -> DiffDocument {
        DiffDocument.build(page: DiffPage.build(files: UnifiedDiff.parse(text).files))
    }

    @Test func aChangeIsARunOfChangedLines() {
        let doc = Self.document("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,6 +1,6 @@\n a\n-b\n+B\n c\n d\n+e\n@@ -20,2 +21,1 @@\n-y\n z\n")
        // Lines: 0 hunk, 1 a, 2 -b, 3 +B, 4 c, 5 d, 6 +e, 7 hunk, 8 -y, 9 z
        #expect(doc.changeStarts == [2, 6, 8])
    }

    @Test func aRefreshedDocumentKeepsTheReadersLine() {
        let before = Self.document("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -10,3 +10,3 @@\n a\n-b\n+B\n c\n")
        // Two lines were added above: everything the reader was looking at moved down two.
        let after = Self.document("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,4 @@\n top\n+one\n+two\n next\n@@ -10,3 +12,3 @@\n a\n-b\n+B\n c\n")
        // `c` was line 4 of the old document. Its new-side number moved from 12 to 14; its old-side
        // number is still 12, and that is what finds it.
        #expect(before.lines[4].newNumber == 12)
        let landed = after.line(matching: 4, of: before)
        #expect(landed == after.lines.count - 1 && after.lines[landed ?? 0].newNumber == 14)
        // An added line is found by the numbered line above it.
        #expect(after.line(matching: 3, of: before) == after.lines.count - 2)
        #expect(after.line(matching: 99, of: before) == nil)
    }

    @Test func aFileWithNoLinesSaysWhy() {
        func body(_ text: String) -> DiffFileBody { UnifiedDiff.parse(text).files[0].body }
        #expect(body("diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n") == .binary)
        #expect(body("diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n") == .renamed(from: "old.txt"))
        #expect(body("diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n") == .mode(old: "100644", new: "100755"))
        #expect(body("diff --git a/e b/e\nnew file mode 100644\nindex 0000000..e69de29\n") == .empty)
        #expect(body("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-one\n+one\r\n") == .lineEndings)
        #expect(body("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-one\n+two\n") == .text)
    }
}
