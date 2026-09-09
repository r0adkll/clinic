import Foundation
import Testing
@testable import ClinicCore

@Suite struct MarkdownSyntaxTests {
    private func kinds(_ text: String) -> [MarkdownSpanKind] {
        MarkdownSyntax.spans(in: text).map(\.kind)
    }

    private func text(_ source: String, _ span: MarkdownSpan) -> String {
        (source as NSString).substring(with: span.range)
    }

    @Test func headingsNeedAMarkerAndASpace() {
        #expect(kinds("# Title") == [.heading])
        #expect(kinds("###### Deep") == [.heading])
        #expect(kinds("####### Too deep").contains(.heading) == false)
        #expect(kinds("#hashtag").contains(.heading) == false)
    }

    @Test func fencedBlocksSwallowTheirContents() {
        let source = """
        # Title
        ```swift
        let x = **not bold**
        ```
        done
        """
        let spans = MarkdownSyntax.spans(in: source)
        #expect(spans.filter { $0.kind == .codeBlock }.count == 3)   // fence, body, fence
        // Nothing inside the block is scanned for inline markup.
        #expect(spans.contains { $0.kind == .strong } == false)
    }

    @Test func inlineCodeWinsOverEmphasis() {
        let source = "a `*not emphasis*` b *yes* c"
        let spans = MarkdownSyntax.spans(in: source)
        let code = try! #require(spans.first { $0.kind == .code })
        #expect(text(source, code) == "`*not emphasis*`")
        let emphasis = try! #require(spans.first { $0.kind == .emphasis })
        #expect(text(source, emphasis) == "*yes*")
    }

    @Test func strongAndEmphasisAreToldApart() throws {
        let source = "**bold** and _italic_"
        let spans = MarkdownSyntax.spans(in: source)
        #expect(text(source, try #require(spans.first { $0.kind == .strong })) == "**bold**")
        #expect(text(source, try #require(spans.first { $0.kind == .emphasis })) == "_italic_")
    }

    @Test func unclosedEmphasisIsJustText() {
        #expect(kinds("2 * 3 = 6").contains(.emphasis) == false)
        #expect(kinds("an * unclosed").contains(.emphasis) == false)
    }

    @Test func linksSplitTextFromDestination() throws {
        let source = "see [the ADR](Decisions/ADR-081.md) please"
        let spans = MarkdownSyntax.spans(in: source)
        #expect(text(source, try #require(spans.first { $0.kind == .linkText })) == "[the ADR]")
        #expect(text(source, try #require(spans.first { $0.kind == .url })) == "(Decisions/ADR-081.md)")
    }

    @Test func autolinksAndBareBracketsAreDistinguished() {
        #expect(kinds("<https://example.com>") == [.url])
        #expect(kinds("a < b and c > d").contains(.url) == false)
    }

    @Test func listMarkersAndQuotesAndBreaks() throws {
        let source = """
        - one
        2. two
        > quoted *text*
        ---
        """
        let spans = MarkdownSyntax.spans(in: source)
        let markers = spans.filter { $0.kind == .marker }
        #expect(markers.count == 3)                                  // "-", "2.", the break
        #expect(text(source, markers[0]) == "-")
        #expect(text(source, markers[1]) == "2.")
        #expect(spans.contains { $0.kind == .quote })
        // A quote line is coloured whole: its inner emphasis is not scanned again.
        #expect(spans.filter { $0.kind == .emphasis }.isEmpty)
    }

    @Test func frontMatterOnlyCountsAtTheTop() {
        let front = """
        ---
        status: accepted
        ---
        # Title
        """
        let spans = MarkdownSyntax.spans(in: front)
        #expect(spans.filter { $0.kind == .comment }.count == 3)
        #expect(spans.last?.kind == .heading)

        // The same `---` further down is a thematic break, not front matter.
        let later = "# Title\n---\nstatus: accepted\n"
        #expect(MarkdownSyntax.spans(in: later).contains { $0.kind == .comment } == false)
    }

    @Test func clippingKeepsOnlyIntersectingSpans() {
        let source = "# Title\n\nbody `code` here\n"
        let tail = NSRange(location: 9, length: source.utf16.count - 9)
        let clipped = MarkdownSyntax.spans(in: source, clippedTo: tail)
        #expect(clipped.contains { $0.kind == .code })
        #expect(clipped.contains { $0.kind == .heading } == false)
    }

    @Test func spansStayInsideTheDocument() {
        let source = """
        # Title *with* `code`
        - [link](url) and **bold**
        > quote
        ```
        fenced
        ```
        """
        let length = (source as NSString).length
        for span in MarkdownSyntax.spans(in: source) {
            #expect(span.range.location >= 0)
            #expect(span.range.location + span.range.length <= length)
        }
    }
}
