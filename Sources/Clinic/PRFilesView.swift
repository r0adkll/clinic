import SwiftUI
import ClinicCore

/// The PR panel's Files tab: a tree of changed files beside one file's diff (ADR-091).
///
/// Deliberately the same shape as the editor panel (ADR-081) rather than the diff panel's single
/// continuous scroll (ADR-080). A PR is read file by file — "what did this change in X" — and a
/// nested tree also shows the *shape* of the change, which a flat rail of 19 paths does not.
@MainActor
@Observable
final class PRFilesModel {
    private(set) var selected: String?
    private(set) var highlights: [String: AttributedString] = [:]
    /// Rows for the selected file only; a PR diff can be thousands of lines and only one file shows.
    private(set) var rows: [DiffRow] = []
    private(set) var columns = 0

    private let highlighter = DiffSyntaxHighlighter()
    private var highlightTask: Task<Void, Never>?
    private var highlightedPath: String?

    /// Picks up the first file when a diff arrives, and re-selects if the chosen file disappears.
    func sync(with diff: UnifiedDiff?) {
        guard let diff, !diff.files.isEmpty else {
            selected = nil; rows = []; highlights = [:]; highlightedPath = nil
            return
        }
        if selected == nil || !diff.files.contains(where: { $0.path == selected }) {
            select(diff.files[0].path, in: diff)
        }
    }

    func select(_ path: String, in diff: UnifiedDiff) {
        guard let file = diff.files.first(where: { $0.path == path }) else { return }
        selected = path
        // `DiffFileRows` has no public initialiser, so the one-file page is built through DiffPage —
        // which is also what gives the highlighter the exact type it wants.
        let page = DiffPage.build(files: [file], limit: 1)
        rows = page.files.first?.rows ?? []
        columns = page.columns
        highlight(page)
    }

    private func highlight(_ page: DiffPage) {
        guard let fileRows = page.files.first, !fileRows.rows.isEmpty else { highlights = [:]; return }
        guard highlightedPath != fileRows.path else { return }
        highlightTask?.cancel()
        highlights = [:]
        highlightedPath = fileRows.path
        let theme = DiffSyntaxTheme.current
        highlightTask = Task { [weak self, highlighter] in
            let result = await highlighter.highlights(for: [fileRows], theme: theme)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.highlightedPath == fileRows.path else { return }
                self.highlights = result
            }
        }
    }
}

struct PRFilesView: View {
    @Environment(PRStore.self) private var prs
    let ref: PullRequestRef
    @Bindable var model: PRFilesModel
    @AppStorage("ClinicPRTreeWidth") private var treeWidth: Double = 210
    @State private var viewport: CGSize = .zero

    /// Gutter is two line-number columns plus the +/− marker, matching `DiffScrollView`.
    private static let gutter: CGFloat = 42 + 42 + 16 + 10
    private var contentWidth: CGFloat {
        max(viewport.width, CGFloat(model.columns) * DiffMetrics.advance + Self.gutter)
    }

    var body: some View {
        Group {
            if let diff = prs.diffs[ref.id] {
                if diff.files.isEmpty {
                    ContentUnavailableView("No file changes", systemImage: "doc", description: Text("This pull request changes nothing."))
                } else {
                    HStack(spacing: 0) {
                        tree(diff)
                            .frame(width: treeWidth)
                        TreeDivider(width: $treeWidth)
                        viewer(diff)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .task(id: diff.files.map(\.path)) { model.sync(with: diff) }
                }
            } else if let error = prs.errors[ref.id], prs.diffs[ref.id] == nil {
                ContentUnavailableView("Could not load the diff", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await prs.loadDiff(ref) }
            }
        }
    }

    private func tree(_ diff: UnifiedDiff) -> some View {
        // `showHidden: true` — a PR that touches `.github/workflows` must not hide those files.
        let nodes = PRFileTree.compress(FileTreeNode.build(from: diff.files.map(\.path), showHidden: true))
        let stats = Dictionary(uniqueKeysWithValues: diff.files.map { ($0.path, $0) })
        return List {
            OutlineGroup(nodes, children: \.children) { node in
                if node.isDirectory {
                    Label(node.name, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                } else {
                    PRFileRow(node: node, file: stats[node.relativePath], selected: model.selected == node.relativePath)
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(node.relativePath, in: diff) }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 22)
    }

    @ViewBuilder
    private func viewer(_ diff: UnifiedDiff) -> some View {
        if let path = model.selected, let file = diff.files.first(where: { $0.path == path }) {
            VStack(spacing: 0) {
                DiffFileHeader(file: file, collapsed: false) {}.allowsHitTesting(false)
                Divider()
                if file.isBinary {
                    ContentUnavailableView("Binary file", systemImage: "doc.badge.gearshape",
                                           description: Text("\(file.additions + file.deletions) bytes changed"))
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.rows) { row in
                                DiffRowView(row: row, attributed: model.highlights[row.id])
                            }
                        }
                        // Same two rules the diff panel needs (ADR-080). Width: the font is
                        // monospaced, so the widest line is arithmetic — without it rows wrap instead
                        // of extending. Height: a two-axis ScrollView centres content shorter than its
                        // viewport, which left a short diff floating in the middle of the pane.
                        .frame(width: contentWidth, alignment: .topLeading)
                        .frame(minHeight: viewport.height, alignment: .topLeading)
                    }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        } else {
            ContentUnavailableView("Select a file", systemImage: "sidebar.left")
        }
    }
}

/// Folds runs of single-child directories into one row (ADR-091).
///
/// A PR tree is not a repo tree: it contains only the touched paths, so a Kotlin or Java project
/// produces chains like `infra/audioplayer/api/src/commonMain/kotlin/com/…` where every level has
/// exactly one child. Expanded one level at a time that is six clicks to reach a file and a tree
/// mostly made of indentation. GitHub and VS Code both collapse these; so does this.
enum PRFileTree {
    static func compress(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes.map { node in
            guard node.isDirectory, var children = node.children else { return node }
            var name = node.name
            var path = node.relativePath
            // Only fold when the single child is itself a directory: a folder holding one file still
            // shows that file as its own row.
            while children.count == 1, let only = children.first, only.isDirectory, let next = only.children {
                name += "/" + only.name
                path = only.relativePath
                children = next
            }
            return FileTreeNode(relativePath: path, name: name, isDirectory: true, children: compress(children))
        }
    }
}

/// One file in the PR tree: glyph, name, and its own +/− so the tree carries the change's shape.
private struct PRFileRow: View {
    let node: FileTreeNode
    let file: UnifiedDiffFile?
    let selected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: FileGlyph.symbol(for: node.name)).font(.caption2).foregroundStyle(.secondary).frame(width: 13)
            Text(node.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let file {
                if file.isNew {
                    Text("A").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                } else if file.isDeleted {
                    Text("D").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                } else {
                    Text("\(file.additions + file.deletions)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Draggable divider between the tree and the viewer.
private struct TreeDivider: View {
    @Binding var width: Double

    var body: some View {
        Divider()
            .overlay(Rectangle().fill(.clear).frame(width: 7).contentShape(Rectangle())
                .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
                .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                    width = min(420, max(140, width + g.translation.width))
                }))
    }
}
