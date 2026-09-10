import SwiftUI
import ClinicCore

/// A set of changed files, browsed as a tree and read one file at a time (ADR-101).
///
/// This is the shape [[ADR-091]] gave the pull request panel's Files tab, and the Diff panel now
/// uses it too: a diff is read file by file — "what did this change in X" — and a nested tree shows
/// the *shape* of a change, which the flat rail it replaced could not.
///
/// The tree, the per-path stats and the ranked filter all live here rather than in a view body
/// (ADR-099): a body runs on every selection and every keystroke, and rebuilding the tree and
/// re-ranking 300 paths each time is what that cost.
@MainActor
@Observable
final class DiffBrowser {
    private(set) var selected: String?
    /// What the viewer renders: the selected file's document and its highlighting.
    let text = DiffTextSource()

    private(set) var nodes: [FileTreeNode] = []
    private(set) var stats: [String: UnifiedDiffFile] = [:]
    private(set) var expanded: Set<String> = []
    private(set) var filtered: [String] = []
    private(set) var paths: [String] = []

    var filter = "" { didSet { guard filter != oldValue else { return }; rank() } }

    private let highlighter = DiffSyntaxHighlighter()
    private var highlightTask: Task<Void, Never>?
    /// The file the document was built from, content and all — so a working tree that moves under
    /// the reader re-renders, and a re-selection of the same unchanged file does not.
    private var rendered: UnifiedDiffFile?
    /// Directories seen the last time the tree was built, so a rebuild can open the ones that are
    /// genuinely new without re-opening the ones the reader closed.
    private var knownDirectories: Set<String> = []

    var visibleRows: [FileTreeRow] { FileTreeNode.rows(nodes, expanded: expanded) }
    var selectedFile: UnifiedDiffFile? { selected.flatMap { stats[$0] } }
    var isEmpty: Bool { paths.isEmpty }
    var fileCount: Int { paths.count }

    func toggle(directory path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    /// Shows a diff. Safe to call on every reload: the tree is rebuilt only when the set of paths
    /// changes, and the reader's selection and expansion survive it.
    func show(_ files: [UnifiedDiffFile]) {
        guard !files.isEmpty else {
            selected = nil; rendered = nil
            nodes = []; stats = [:]; expanded = []; knownDirectories = []; paths = []; filtered = []
            text.replace(document: DiffDocument(), keepingTokens: false)
            return
        }
        stats = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let incoming = files.map(\.path)
        if incoming != paths {
            paths = incoming
            // `showHidden: true` — a change that touches `.github/workflows` must not hide it.
            nodes = FileTreeNode.compress(FileTreeNode.build(from: paths, showHidden: true))
            let directories = FileTreeNode.directories(nodes)
            // Fully open on arrival: the tree holds only the touched paths, so "everything" is a
            // dozen or two rows, and opening onto three collapsed folders makes the reader click
            // their way to the change they came to read (ADR-099). On a later reload only the new
            // directories open, so a folder the reader closed stays closed.
            expanded = knownDirectories.isEmpty ? directories
                                                : expanded.union(directories.subtracting(knownDirectories))
            knownDirectories = directories
            rank()
        }
        if let path = selected, let file = stats[path] {
            render(file)                     // same file, possibly new content
        } else {
            select(files[0].path)
        }
    }

    func select(_ path: String) {
        guard let file = stats[path] else { return }
        selected = path
        render(file)
    }

    /// Fuzzy rather than substring, and the same matcher Quick Open uses, so "pbt" finds
    /// `PlaybackTimer.kt` here exactly as it does there (ADR-092).
    private func rank() {
        filtered = filter.isEmpty ? [] : FuzzyMatcher.rank(filter, candidates: paths, limit: 300).map(\.candidate)
    }

    /// Builds one file's document and asks for its colours. Rows are built for this file alone, so
    /// there is no page budget to keep: ADR-080's 20,000-row limit existed because the panel
    /// rendered a whole scope at once (ADR-101).
    private func render(_ file: UnifiedDiffFile) {
        guard file != rendered else { return }
        rendered = file
        highlightTask?.cancel()
        let page = DiffPage.build(files: [file])
        text.replace(document: DiffDocument.build(page: page), keepingTokens: false)
        guard let rows = page.files.first, !rows.rows.isEmpty else { return }
        let theme = DiffSyntaxTheme.current
        highlightTask = Task { [weak self, highlighter] in
            let result = await highlighter.highlights(for: [rows], theme: theme)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.rendered == file else { return }
                self.text.merge(tokens: result)
            }
        }
    }
}

/// The browser: a file tree beside one file's diff.
///
/// Two columns, each with its own header, and one divider running the whole height between them —
/// so the filter belongs visibly to the list it filters and the file's name to the diff it names.
/// The tree's header and the file's used to be stacked rows spanning both columns, which cost a
/// third row of chrome and left the file bar looking like it belonged to the tree as well.
struct DiffBrowserView: View {
    @Bindable var browser: DiffBrowser
    @Binding var showTree: Bool
    /// The persisted width. The drag moves `live` and only commits here when it ends, so a
    /// preference is written once per drag rather than many times a second.
    @Binding var treeWidth: Double

    /// The width on screen while a drag is in flight; zero until the reader drags for the first
    /// time, at which point the stored width takes over. The column reads *this*, which is what the
    /// first version got wrong: it drew from the stored width, so nothing moved until the drag
    /// ended and then the column jumped.
    @State private var live: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = clamped(live > 0 ? live : CGFloat(treeWidth), in: geo.size.width)
            HStack(spacing: 0) {
                if showTree {
                    VStack(spacing: 0) {
                        filterBar
                        Divider()
                        sidebar
                    }
                    .frame(width: width)
                    TreeSplitHandle(width: $live,
                                    base: width,
                                    clamp: { clamped($0, in: geo.size.width) },
                                    commit: { treeWidth = Double($0) })
                }
                VStack(spacing: 0) {
                    fileBar
                    Divider()
                    viewer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Never below a readable list, never leaving the diff under 240 pt — the same shape of rule the
    /// Files panel applies to its own column (ADR-081).
    private func clamped(_ width: CGFloat, in available: CGFloat) -> CGFloat {
        let upper = max(140, min(420, available - 240))
        return min(max(width, 140), upper)
    }

    private var filterBar: some View {
        PaneHeader {
            TreeToggleButton(isOn: $showTree)
            TreeFilterField(text: $browser.filter, matches: browser.filtered.count, total: browser.fileCount)
        }
    }

    /// Names the file the viewer is showing, and carries its counts and its status. It is the only
    /// header the diff has now that the body renders one file (ADR-101).
    @ViewBuilder
    private var fileBar: some View {
        PaneHeader {
            if !showTree { TreeToggleButton(isOn: $showTree) }
            if let file = browser.selectedFile {
                Text(file.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
                    .help(file.path)
                if let status = DiffFileStatus(file) { status.label }
                Spacer(minLength: 8)
                Text("+\(file.additions)").foregroundStyle(.green).font(.caption.monospacedDigit())
                Text("−\(file.deletions)").foregroundStyle(.red).font(.caption.monospacedDigit())
            } else {
                Text(browser.isEmpty ? "No changes" : "Select a file")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .contextMenu {
            if let path = browser.selected {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        }
    }

    /// A tree while browsing, a ranked flat list while filtering. Searching is a different act from
    /// browsing: the hierarchy is what you want when you do not know the name, and pure noise once
    /// you are typing one.
    @ViewBuilder
    private var sidebar: some View {
        if browser.filter.isEmpty {
            tree
        } else if browser.filtered.isEmpty {
            VStack {
                Text("No matching files").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FileTreeScroll {
                ForEach(browser.filtered, id: \.self) { path in
                    FileTreeRowView(name: (path as NSString).lastPathComponent,
                                    subtitle: (path as NSString).deletingLastPathComponent,
                                    symbol: FileGlyph.symbol(for: path),
                                    isSelected: browser.selected == path,
                                    help: path,
                                    accessory: { DiffFileStat(file: browser.stats[path]) }) { browser.select(path) }
                }
            }
        }
    }

    /// The same flat rows the Files panel draws (ADR-099): full-width targets, and a tap on a folder
    /// row anywhere opens or closes it.
    private var tree: some View {
        ScrollViewReader { proxy in
            FileTreeScroll {
                ForEach(browser.visibleRows) { row in
                    FileTreeRowView(name: row.name,
                                    depth: row.depth,
                                    symbol: row.isDirectory ? (row.isExpanded ? "folder.fill" : "folder") : FileGlyph.symbol(for: row.name),
                                    isExpanded: row.isDirectory ? row.isExpanded : nil,
                                    isSelected: !row.isDirectory && browser.selected == row.path,
                                    help: row.path,
                                    accessory: { if !row.isDirectory { DiffFileStat(file: browser.stats[row.path]) } }) {
                        if row.isDirectory { browser.toggle(directory: row.path) } else { browser.select(row.path) }
                    }
                    .id(row.path)
                }
            }
            .onChange(of: browser.selected) {
                guard let path = browser.selected else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(path, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var viewer: some View {
        if let file = browser.selectedFile {
            if file.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc.badge.gearshape",
                                       description: Text("\(file.additions + file.deletions) bytes changed"))
            } else {
                DiffTextBody(source: browser.text)
            }
        } else {
            ContentUnavailableView("Select a file", systemImage: "sidebar.left")
        }
    }
}

/// What happened to a file, when it is not a plain edit — the one thing the tree's A/D badge cannot
/// say (it has no room for "renamed").
enum DiffFileStatus {
    case added, deleted, renamed

    init?(_ file: UnifiedDiffFile) {
        if file.isNew { self = .added }
        else if file.isDeleted { self = .deleted }
        else if let old = file.oldPath, let new = file.newPath, old != new { self = .renamed }
        else { return nil }
    }

    var title: String {
        switch self {
        case .added: "new"
        case .deleted: "deleted"
        case .renamed: "renamed"
        }
    }

    var colour: Color {
        switch self {
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        }
    }

    var label: some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(colour)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(colour.opacity(0.12), in: Capsule())
    }
}

/// A changed file's own +/− count, or its A/D badge — so the list carries the shape of the change
/// and not just its paths (ADR-091). The trailing accessory of a shared file-tree row (ADR-099).
struct DiffFileStat: View {
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
