import Foundation
import Testing
@testable import ClinicCore

@Suite struct FileLinkTests {
    private let files: Set<String> = ["/repo/README.md", "/repo/Sources/App.swift", "/repo/My Notes/plan.md"]
    private func resolve(_ url: URL, cwd: String? = "/repo") -> FileLink? {
        FileLink.resolve(url, cwd: cwd) { files.contains($0) }
    }

    @Test func theCLIsFileURLsResolveAsTheyAre() {
        #expect(resolve(URL(string: "file:///repo/README.md")!) == FileLink(path: "/repo/README.md"))
        #expect(resolve(URL(string: "file:///repo/My%20Notes/plan.md")!) == FileLink(path: "/repo/My Notes/plan.md"))
    }

    @Test func aFragmentNamesALine() {
        #expect(resolve(URL(string: "file:///repo/Sources/App.swift#L42")!) == FileLink(path: "/repo/Sources/App.swift", line: 42))
        #expect(resolve(URL(string: "file:///repo/Sources/App.swift#7")!)?.line == 7)
    }

    @Test func relativePathsResolveAgainstTheShell() {
        #expect(resolve(URL(filePath: "Sources/App.swift")) == FileLink(path: "/repo/Sources/App.swift"))
        #expect(resolve(URL(filePath: "./README.md")) == FileLink(path: "/repo/README.md"))
        #expect(resolve(URL(filePath: "README.md"), cwd: nil) == nil)
    }

    @Test func aTrailingLineAndColumnAreSplitOff() {
        #expect(resolve(URL(filePath: "/repo/Sources/App.swift:12")) == FileLink(path: "/repo/Sources/App.swift", line: 12))
        #expect(resolve(URL(filePath: "Sources/App.swift:12:5")) == FileLink(path: "/repo/Sources/App.swift", line: 12, column: 5))
    }

    @Test func aNameWithADotParsesAsASchemeAndIsStillAPath() {
        // `URL(string: "README.md:3")` has the scheme `README.md`.
        let url = URL(string: "README.md:3")!
        #expect(url.scheme == "README.md")
        #expect(resolve(url) == FileLink(path: "/repo/README.md", line: 3))
    }

    @Test func otherPlacesAreNotFiles() {
        #expect(resolve(URL(string: "https://github.com/r0adkll/clinic")!) == nil)
        #expect(resolve(URL(string: "file:///repo/Sources")!) == nil)
        #expect(resolve(URL(string: "file:///repo/missing.md")!) == nil)
    }
}

@Suite struct MarkdownDocumentTests {
    @Test func frontMatterIsSplitAndItsLinesKept() {
        let text = "---\ntitle: x\ntags: [a]\n---\n# Heading\nbody"
        let (yaml, body) = MarkdownDocument.split(text)
        #expect(yaml == "title: x\ntags: [a]")
        #expect(body == "\n\n\n\n# Heading\nbody")
        #expect(body.components(separatedBy: "\n").count == text.components(separatedBy: "\n").count)
    }

    @Test func aRuleThatIsNotFirstOrNeverClosesIsNotFrontMatter() {
        #expect(MarkdownDocument.split("# Title\n---\nx: y\n---").frontMatter == nil)
        #expect(MarkdownDocument.split("---\nnot closed").frontMatter == nil)
    }

    @Test func wikiLinksFindTheirNote() {
        let paths = ["docs/00 Home.md", "docs/Decisions/ADR-081 Files Panel Focus Modes.md",
                     "docs/Design/Design Tree.md", "README.md", "docs/README.md", "docs/img/shot.png"]
        let from = "docs/Design/Design Tree.md"
        #expect(MarkdownDocument.resolveWikiLink("ADR-081 Files Panel Focus Modes", from: from, in: paths)
                == "docs/Decisions/ADR-081 Files Panel Focus Modes.md")
        #expect(MarkdownDocument.resolveWikiLink("adr-081 files panel focus modes#Decision", from: from, in: paths)
                == "docs/Decisions/ADR-081 Files Panel Focus Modes.md")
        #expect(MarkdownDocument.resolveWikiLink("shot.png", from: from, in: paths) == "docs/img/shot.png")
        #expect(MarkdownDocument.resolveWikiLink("Missing", from: from, in: paths) == nil)
    }

    @Test func aNameInSeveralPlacesPrefersTheNeighbourThenTheShallowest() {
        let paths = ["README.md", "docs/README.md", "docs/deep/README.md"]
        #expect(MarkdownDocument.resolveWikiLink("README", from: "docs/x.md", in: paths) == "docs/README.md")
        #expect(MarkdownDocument.resolveWikiLink("README", from: "other/x.md", in: paths) == "README.md")
    }
}
