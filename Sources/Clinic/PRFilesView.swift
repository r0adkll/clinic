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
    /// The selected file only; a PR diff can be thousands of lines and only one file shows.
    let text = DiffTextSource()

    private let highlighter = DiffSyntaxHighlighter()
    private var highlightTask: Task<Void, Never>?
    private var highlightedPath: String?

    /// Picks up the first file when a diff arrives, and re-selects if the chosen file disappears.
    func sync(with diff: UnifiedDiff?) {
        guard let diff, !diff.files.isEmpty else {
            selected = nil
            text.replace(document: DiffDocument(), keepingTokens: false)
            highlightedPath = nil
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
        text.replace(document: DiffDocument.build(page: page), keepingTokens: false)
        highlight(page)
    }

    private func highlight(_ page: DiffPage) {
        guard let fileRows = page.files.first, !fileRows.rows.isEmpty else { return }
        guard highlightedPath != fileRows.path else { return }
        highlightTask?.cancel()
        highlightedPath = fileRows.path
        let theme = DiffSyntaxTheme.current
        highlightTask = Task { [weak self, highlighter] in
            let result = await highlighter.highlights(for: [fileRows], theme: theme)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.highlightedPath == fileRows.path else { return }
                self.text.merge(tokens: result)
            }
        }
    }
}

struct PRFilesView: View {
    @Environment(PRStore.self) private var prs
    let ref: PullRequestRef
    @Bindable var model: PRFilesModel
    @AppStorage("ClinicPRTreeWidth") private var treeWidth: Double = 210
    /// Separate from the editor panel's `ClinicEditorShowTree`: these are different surfaces and a
    /// reader who wants the repo tree open does not necessarily want a PR's file list open too.
    @AppStorage("ClinicPRShowTree") private var showTree = true
    @State private var filter = ""
    @State private var scrollTarget: String?
    @FocusState private var filterFocused: Bool

    var body: some View {
        Group {
            if let diff = prs.diffs[ref.id] {
                if diff.files.isEmpty {
                    ContentUnavailableView("No file changes", systemImage: "doc", description: Text("This pull request changes nothing."))
                } else {
                    VStack(spacing: 0) {
                        toolbar(diff)
                        Divider()
                        HStack(spacing: 0) {
                            if showTree {
                                sidebar(diff)
                                    .frame(width: treeWidth)
                                TreeDivider(width: $treeWidth)
                            }
                            viewer(diff)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
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

    /// Always on screen in both tree states, so the toggle can never hide itself (the rule the editor
    /// panel's header follows, ADR-081). The filter field belongs to the list, so it goes away with it.
    private func toolbar(_ diff: UnifiedDiff) -> some View {
        HStack(spacing: 6) {
            Button { showTree.toggle() } label: {
                Image(systemName: showTree ? "sidebar.left" : "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(showTree ? Color.accentColor : Color.secondary)
            .help(showTree ? "Hide the file list" : "Show the file list")

            if showTree {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.tertiary)
                    TextField("Filter files", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .focused($filterFocused)
                        .onKeyPress(.escape) {
                            if filter.isEmpty { return .ignored }
                            filter = ""; return .handled
                        }
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").font(.caption2) }
                            .buttonStyle(.borderless).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .frame(maxWidth: treeWidth)
            } else if let path = model.selected {
                Text(path).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            if showTree, !filter.isEmpty {
                Text("\(matches(diff).count) of \(diff.files.count)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    /// Ranked paths for the current filter. Fuzzy rather than substring, and the same matcher Quick
    /// Open uses, so "pbt" finds `PlaybackTimer.kt` here exactly as it does there (ADR-092).
    private func matches(_ diff: UnifiedDiff) -> [String] {
        FuzzyMatcher.rank(filter, candidates: diff.files.map(\.path), limit: 300).map(\.candidate)
    }

    /// A tree while browsing, a ranked flat list while filtering. Searching is a different act from
    /// browsing: the hierarchy is what you want when you do not know the name, and pure noise once
    /// you are typing one.
    @ViewBuilder
    private func sidebar(_ diff: UnifiedDiff) -> some View {
        if filter.isEmpty {
            tree(diff)
        } else {
            let paths = matches(diff)
            let stats = Dictionary(uniqueKeysWithValues: diff.files.map { ($0.path, $0) })
            if paths.isEmpty {
                VStack {
                    Text("No matching files").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(paths, id: \.self) { path in
                    PRFilterResultRow(path: path, file: stats[path], selected: model.selected == path)
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(path, in: diff) }
                }
                .listStyle(.sidebar)
                .environment(\.defaultMinListRowHeight, 30)
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
                DiffFileHeader(file: file)
                if file.isBinary {
                    ContentUnavailableView("Binary file", systemImage: "doc.badge.gearshape",
                                           description: Text("\(file.additions + file.deletions) bytes changed"))
                } else {
                    // The same body the diff panel renders (ADR-100), fed a one-file document.
                    DiffTextBody(source: model.text, scrollTarget: $scrollTarget)
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

/// A filter hit: file name, then its directory dimmed behind it — the Quick Open row, narrower.
private struct PRFilterResultRow: View {
    let path: String
    let file: UnifiedDiffFile?
    let selected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: FileGlyph.symbol(for: path)).font(.caption2).foregroundStyle(.secondary).frame(width: 13)
            VStack(alignment: .leading, spacing: 0) {
                Text((path as NSString).lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                let dir = (path as NSString).deletingLastPathComponent
                if !dir.isEmpty {
                    Text(dir).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
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
