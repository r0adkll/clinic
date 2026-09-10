import Foundation
import Testing
@testable import ClinicCore

@Suite struct FileTreeTests {
    private let paths = [
        "Sources/Clinic/EditorPanel.swift",
        "Sources/Clinic/PRFilesView.swift",
        "Sources/clinic-hook/main.swift",
        "README.md",
        ".github/workflows/ci.yml",
    ]

    @Test func buildsDirectoriesFirstAndHidesDotPaths() {
        let visible = FileTreeNode.build(from: paths, showHidden: false)
        #expect(visible.map(\.name) == ["Sources", "README.md"])
        #expect(visible.first?.isDirectory == true)
        let hidden = FileTreeNode.build(from: paths, showHidden: true)
        #expect(hidden.map(\.name) == [".github", "Sources", "README.md"])
    }

    @Test func compressFoldsSingleChildDirectoryChainsAndKeepsTheDeepestPath() {
        let folded = FileTreeNode.compress(FileTreeNode.build(from: [".github/workflows/ci.yml"], showHidden: true))
        #expect(folded.count == 1)
        #expect(folded[0].name == ".github/workflows")
        // The identity is the deepest folded directory, so a prefix-built expansion set names it.
        #expect(folded[0].relativePath == ".github/workflows")
        #expect(folded[0].children?.map(\.name) == ["ci.yml"])
    }

    @Test func compressStopsAtADirectoryHoldingOneFile() {
        // `clinic-hook` holds exactly one child, but it is a file: it stays its own row.
        let folded = FileTreeNode.compress(FileTreeNode.build(from: ["clinic-hook/main.swift"], showHidden: false))
        #expect(folded.map(\.name) == ["clinic-hook"])
        #expect(folded[0].children?.map(\.name) == ["main.swift"])
    }

    @Test func rowsOnlyDescendIntoOpenDirectories() {
        let tree = FileTreeNode.build(from: paths, showHidden: false)
        let closed = FileTreeNode.rows(tree, expanded: [])
        #expect(closed.map(\.name) == ["Sources", "README.md"])
        #expect(closed.allSatisfy { $0.depth == 0 })
        #expect(closed[0].isExpanded == false)

        let open = FileTreeNode.rows(tree, expanded: ["Sources"])
        #expect(open.map(\.name) == ["Sources", "Clinic", "clinic-hook", "README.md"])
        #expect(open[0].isExpanded)
        #expect(open[1].depth == 1)
        // "Clinic" is closed, so its two files are not rows.
        #expect(open[1].isExpanded == false)
    }

    @Test func rowsGoAllTheWayDownWhenEveryDirectoryIsOpen() {
        let tree = FileTreeNode.build(from: paths, showHidden: false)
        let rows = FileTreeNode.rows(tree, expanded: FileTreeNode.directories(tree))
        #expect(rows.map(\.name) == ["Sources", "Clinic", "EditorPanel.swift", "PRFilesView.swift",
                                     "clinic-hook", "main.swift", "README.md"])
        #expect(rows.first { $0.name == "EditorPanel.swift" }?.depth == 2)
        #expect(rows.first { $0.name == "EditorPanel.swift" }?.isDirectory == false)
    }

    @Test func directoriesNamesEveryFolderAndNoFile() {
        let tree = FileTreeNode.build(from: paths, showHidden: true)
        #expect(FileTreeNode.directories(tree) == [".github", ".github/workflows", "Sources", "Sources/Clinic", "Sources/clinic-hook"])
    }

    @Test func ancestorsAreEveryPrefixSoAFoldedRowIsNamedToo() {
        #expect(FileTreeNode.ancestors(of: "Sources/Clinic/EditorPanel.swift") == ["Sources", "Sources/Clinic"])
        #expect(FileTreeNode.ancestors(of: "README.md").isEmpty)
        // A compressed `.github/workflows` row is named by the prefix set, which is what lets
        // "reveal the file I just opened" work on a folded tree.
        #expect(FileTreeNode.ancestors(of: ".github/workflows/ci.yml").contains(".github/workflows"))
    }

    @Test func revealingAFileMakesItAVisibleRow() {
        let tree = FileTreeNode.build(from: paths, showHidden: false)
        let target = "Sources/Clinic/PRFilesView.swift"
        let rows = FileTreeNode.rows(tree, expanded: FileTreeNode.ancestors(of: target))
        #expect(rows.contains { $0.path == target })
    }
}
