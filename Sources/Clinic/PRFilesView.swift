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

    /// The tree, its per-path stats and the ranked filter all live here rather than being rebuilt in
    /// `body` (ADR-099). The view's body runs on every selection and every keystroke, and it was
    /// re-walking the whole diff and re-ranking 300 paths each time.
    private(set) var nodes: [FileTreeNode] = []
    private(set) var stats: [String: UnifiedDiffFile] = [:]
    /// Every directory, until the reader closes one: see `sync`.
    private(set) var expanded: Set<String> = []
    private(set) var filtered: [String] = []
    private var paths: [String] = []

    private let highlighter = DiffSyntaxHighlighter()
    private var highlightTask: Task<Void, Never>?
    private var highlightedPath: String?

    var filter = "" { didSet { guard filter != oldValue else { return }; rank() } }

    var visibleRows: [FileTreeRow] { FileTreeNode.rows(nodes, expanded: expanded) }

    func toggle(directory path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    /// Picks up the first file when a diff arrives, and re-selects if the chosen file disappears.
    func sync(with diff: UnifiedDiff?) {
        guard let diff, !diff.files.isEmpty else {
            selected = nil
            text.replace(document: DiffDocument(), keepingTokens: false)
            highlightedPath = nil
            nodes = []; stats = [:]; expanded = []; paths = []; filtered = []
            return
        }
        paths = diff.files.map(\.path)
        stats = Dictionary(diff.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        // `showHidden: true` — a PR that touches `.github/workflows` must not hide those files.
        nodes = FileTreeNode.compress(FileTreeNode.build(from: paths, showHidden: true))
        // Fully open on arrival: the tree holds only the touched paths, so "everything" is a dozen
        // or two rows, and a Files tab that opens onto three collapsed folders makes the reader
        // click their way to the change they came to read (ADR-099).
        expanded = FileTreeNode.directories(nodes)
        rank()
        if selected == nil || !diff.files.contains(where: { $0.path == selected }) {
            select(diff.files[0].path, in: diff)
        }
    }

    /// Fuzzy rather than substring, and the same matcher Quick Open uses, so "pbt" finds
    /// `PlaybackTimer.kt` here exactly as it does there (ADR-092).
    private func rank() {
        filtered = filter.isEmpty ? [] : FuzzyMatcher.rank(filter, candidates: paths, limit: 300).map(\.candidate)
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
                    TextField("Filter files", text: $model.filter)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .focused($filterFocused)
                        .onKeyPress(.escape) {
                            if model.filter.isEmpty { return .ignored }
                            model.filter = ""; return .handled
                        }
                    if !model.filter.isEmpty {
                        Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill").font(.caption2) }
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
            if showTree, !model.filter.isEmpty {
                Text("\(model.filtered.count) of \(diff.files.count)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    /// A tree while browsing, a ranked flat list while filtering. Searching is a different act from
    /// browsing: the hierarchy is what you want when you do not know the name, and pure noise once
    /// you are typing one.
    @ViewBuilder
    private func sidebar(_ diff: UnifiedDiff) -> some View {
        if model.filter.isEmpty {
            tree(diff)
        } else if model.filtered.isEmpty {
            VStack {
                Text("No matching files").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FileTreeScroll {
                ForEach(model.filtered, id: \.self) { path in
                    FileTreeRowView(name: (path as NSString).lastPathComponent,
                                    subtitle: (path as NSString).deletingLastPathComponent,
                                    symbol: FileGlyph.symbol(for: path),
                                    isSelected: model.selected == path,
                                    help: path,
                                    accessory: { PRFileStat(file: model.stats[path]) }) { model.select(path, in: diff) }
                }
            }
        }
    }

    /// The same flat rows the Files panel draws (ADR-099): full-width targets, and a tap on a folder
    /// row anywhere opens or closes it.
    private func tree(_ diff: UnifiedDiff) -> some View {
        ScrollViewReader { proxy in
            FileTreeScroll {
                ForEach(model.visibleRows) { row in
                    FileTreeRowView(name: row.name,
                                    depth: row.depth,
                                    symbol: row.isDirectory ? (row.isExpanded ? "folder.fill" : "folder") : FileGlyph.symbol(for: row.name),
                                    isExpanded: row.isDirectory ? row.isExpanded : nil,
                                    isSelected: !row.isDirectory && model.selected == row.path,
                                    help: row.path,
                                    accessory: { if !row.isDirectory { PRFileStat(file: model.stats[row.path]) } }) {
                        if row.isDirectory { model.toggle(directory: row.path) } else { model.select(row.path, in: diff) }
                    }
                    .id(row.path)
                }
            }
            .onChange(of: model.selected) {
                guard let path = model.selected else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(path, anchor: .center) }
            }
        }
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

/// A changed file's own +/− count, or its A/D badge — so the list carries the shape of the change
/// and not just its paths (ADR-091). The trailing accessory of a shared file-tree row (ADR-099).
private struct PRFileStat: View {
    let file: UnifiedDiffFile?

    var body: some View {
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
