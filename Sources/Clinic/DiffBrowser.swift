import SwiftUI
import ClinicCore

/// Where a diff's files can be read whole (ADR-186, ADR-188): the two trees it was made from. A diff
/// with no trees behind it — a pull request's, fetched as text — has none, and the browser does
/// without: per-hunk highlighting, and no whole-file view.
struct DiffContentSource: Sendable {
    enum Side: Sendable { case old, new }
    /// The file's text on one side, or nil when it is not text worth parsing whole.
    var text: @Sendable (UnifiedDiffFile, Side) async -> String?
    /// The file's bytes on one side, whatever they are — a picture's, for the media viewer (ADR-189).
    var data: @Sendable (UnifiedDiffFile, Side) async -> Data?
    /// The file's diff with the whole file as context.
    var whole: @Sendable (UnifiedDiffFile) async -> UnifiedDiffFile?
}

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
    /// The files in the order the tree lists them, which is the order "next file" walks (ADR-188).
    private(set) var ordered: [String] = []

    var filter = "" { didSet { guard filter != oldValue else { return }; rank() } }

    /// The file on screen is no longer part of the diff (ADR-187): the diff refreshed under the
    /// reader and this file left it. It stays on screen, marked, until the reader picks another —
    /// the alternative is the body silently becoming a different file.
    private(set) var selectionLeftDiff = false
    /// Files the reader has marked viewed, each against the contents it had then (ADR-188). A file
    /// that changes again is no longer the file that was read, so its mark lapses on its own.
    private(set) var viewed: [String: String] = [:]
    /// Each change shown inside its whole file rather than three lines of it (ADR-188).
    var showsWholeFile = false { didSet { if showsWholeFile != oldValue, let file = selectedFile { render(file, newFile: false) } } }
    /// Whether the diff on screen can be read whole; false for a pull request's.
    var canShowWholeFile: Bool { source != nil }
    /// Whether a picture in the diff can be shown as one (ADR-189): its sides are read from the
    /// trees, so a pull request's diff, which is only text, cannot.
    var canShowMedia: Bool { source != nil }
    /// A picture that is also text — an SVG — shown as its source diff rather than drawn (ADR-189).
    var showsMediaSource = false

    /// The file on screen is a picture the viewer can draw, and the reader has not asked for its text.
    var showsMedia: Bool {
        guard canShowMedia, let file = selectedFile, MediaFile.isMedia(file.path) else { return false }
        switch file.body {
        case .binary: return true
        case .text, .lineEndings: return !showsMediaSource
        case .renamed, .mode, .empty: return false
        }
    }

    /// A picture whose diff also has a text form, so the file bar can offer the switch.
    var hasMediaSource: Bool {
        guard canShowMedia, let file = selectedFile, MediaFile.isMedia(file.path) else { return false }
        return file.body == .text || file.body == .lineEndings
    }

    func data(of file: UnifiedDiffFile, side: DiffContentSource.Side) async -> Data? {
        await source?.data(file, side)
    }

    private var source: DiffContentSource?
    private let highlighter = DiffSyntaxHighlighter()
    private var renderTask: Task<Void, Never>?
    /// The file the document was built from, content and all — so a working tree that moves under
    /// the reader re-renders, and a re-selection of the same unchanged file does not.
    private var rendered: UnifiedDiffFile?
    private var renderedWhole = false
    /// Directories seen the last time the tree was built, so a rebuild can open the ones that are
    /// genuinely new without re-opening the ones the reader closed.
    private var knownDirectories: Set<String> = []
    /// The reader chose the file on screen, rather than being shown it.
    private var pickedByReader = false

    var visibleRows: [FileTreeRow] { FileTreeNode.rows(nodes, expanded: expanded) }
    var selectedFile: UnifiedDiffFile? { selectionLeftDiff ? rendered : selected.flatMap { stats[$0] } }
    var isEmpty: Bool { paths.isEmpty }
    var fileCount: Int { paths.count }
    /// The reader is in the middle of something here: they picked this file, or have scrolled into
    /// it. What the panel checks before it moves the content under them (ADR-187).
    var isEngaged: Bool { pickedByReader || text.isScrolled }

    func toggle(directory path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    /// Shows a diff. Safe to call on every reload: the tree is rebuilt only when the set of paths
    /// changes, and the reader's selection and expansion survive it.
    ///
    /// `fresh` says the reader asked for a different diff — another scope, another turn, another
    /// pull request — as opposed to the same one refreshing. Only a fresh diff may move the
    /// selection (ADR-187).
    func show(_ files: [UnifiedDiffFile], source: DiffContentSource? = nil, fresh: Bool = true) {
        self.source = source
        guard !files.isEmpty else {
            renderTask?.cancel()
            selected = nil; rendered = nil; selectionLeftDiff = false; pickedByReader = false
            nodes = []; stats = [:]; expanded = []; knownDirectories = []; paths = []; filtered = []; ordered = []
            text.replace(document: DiffDocument(), keepingTokens: false, newFile: true)
            return
        }
        stats = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let incoming = files.map(\.path)
        if incoming != paths {
            paths = incoming
            // `showHidden: true` — a change that touches `.github/workflows` must not hide it.
            nodes = FileTreeNode.compress(FileTreeNode.build(from: paths, showHidden: true))
            ordered = Self.files(in: nodes)
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
        viewed = viewed.filter { stats[$0.key]?.contentKey == $0.value }
        if fresh { pickedByReader = false }
        if let path = selected, let file = stats[path] {
            selectionLeftDiff = false
            render(file, newFile: false)     // same file, possibly new content
        } else if !fresh, selected != nil, rendered != nil {
            selectionLeftDiff = true         // stays on screen; the file bar says so
        } else if let first = ordered.first ?? files.first?.path {
            // The first file as the tree lists it, not as git sorted it: the row at the top.
            select(first, byReader: false)
        }
    }

    func select(_ path: String, byReader: Bool = true) {
        guard let file = stats[path] else { return }
        let changed = selected != path || selectionLeftDiff
        selected = path
        selectionLeftDiff = false
        if byReader { pickedByReader = true }
        render(file, newFile: changed)
    }

    /// Forgets that the reader was in the middle of this diff: the panel came back to the front, or
    /// they asked to be shown the newest change (ADR-187).
    func disengage() { pickedByReader = false }

    // MARK: Review (ADR-188)

    func isViewed(_ path: String) -> Bool {
        guard let key = viewed[path] else { return false }
        return stats[path]?.contentKey == key
    }

    var viewedCount: Int { paths.reduce(0) { $0 + (isViewed($1) ? 1 : 0) } }

    /// Marks the file on screen viewed and moves to the next one not yet viewed; on a viewed file,
    /// takes the mark off and stays.
    func toggleViewed() {
        guard !selectionLeftDiff, let path = selected, let file = stats[path] else { return }
        if isViewed(path) {
            viewed[path] = nil
            return
        }
        viewed[path] = file.contentKey
        guard let index = ordered.firstIndex(of: path) else { return }
        let after = ordered[(index + 1)...] + ordered[..<index]
        if let next = after.first(where: { !isViewed($0) }) { select(next) }
    }

    /// The file before or after the one on screen, in tree order. Stops at either end.
    @discardableResult
    func selectAdjacentFile(_ delta: Int) -> Bool {
        guard !ordered.isEmpty else { return false }
        guard let path = selected, !selectionLeftDiff, let index = ordered.firstIndex(of: path) else {
            select(delta >= 0 ? ordered[0] : ordered[ordered.count - 1])
            return true
        }
        let next = index + delta
        guard ordered.indices.contains(next) else { return false }
        reveal(ordered[next])
        select(ordered[next])
        return true
    }

    /// The next or previous change from where the body is scrolled to, running on into the next
    /// file when this one has no more: one key reads a whole diff.
    func goToChange(_ delta: Int) {
        let starts = text.document.changeStarts
        // "Where the reader is" is a few lines below the top, which is where `reveal` puts a change.
        let here = text.topLine + 3
        if delta > 0, let next = starts.first(where: { $0 > here }) { text.reveal(line: next); return }
        if delta < 0, let previous = starts.last(where: { $0 < here }) { text.reveal(line: previous); return }
        guard selectAdjacentFile(delta) else { return }
        let landed = text.document.changeStarts
        if let line = delta > 0 ? landed.first : landed.last { text.reveal(line: line) }
    }

    var canGoToFile: (previous: Bool, next: Bool) {
        guard let path = selected, let index = ordered.firstIndex(of: path) else { return (!ordered.isEmpty, !ordered.isEmpty) }
        return (index > 0, index < ordered.count - 1)
    }

    /// Opens every folder above `path`, so the row it selects is on screen.
    private func reveal(_ path: String) {
        var prefix = ""
        for part in path.split(separator: "/").dropLast() {
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            expanded.insert(prefix)
        }
        // A compressed chain (`a/b/c` as one row) is keyed by its deepest path, which is in the loop above.
    }

    private static func files(in nodes: [FileTreeNode]) -> [String] {
        var out: [String] = []
        func walk(_ nodes: [FileTreeNode]) {
            for node in nodes {
                if node.isDirectory { walk(node.children ?? []) } else { out.append(node.relativePath) }
            }
        }
        walk(nodes)
        return out
    }

    /// Fuzzy rather than substring, and the same matcher Quick Open uses, so "pbt" finds
    /// `PlaybackTimer.kt` here exactly as it does there (ADR-092).
    private func rank() {
        filtered = filter.isEmpty ? [] : FuzzyMatcher.rank(filter, candidates: paths, limit: 300).map(\.candidate)
    }

    /// Builds one file's document and asks for its colours. Rows are built for this file alone, so
    /// there is no page budget to keep: ADR-080's 20,000-row limit existed because the panel
    /// rendered a whole scope at once (ADR-101).
    ///
    /// `newFile` is what sends the body back to the top. The same file with new contents keeps the
    /// reader's line, and keeps its old colours until the new ones land, so a file being written
    /// while it is read neither jumps nor flashes to plain text (ADR-186).
    private func render(_ file: UnifiedDiffFile, newFile: Bool) {
        let whole = showsWholeFile && source != nil
        guard file != rendered || whole != renderedWhole else { return }
        rendered = file
        renderedWhole = whole
        renderTask?.cancel()
        let source = self.source
        if !whole { put(file, newFile: newFile) }
        renderTask = Task { [weak self, highlighter] in
            var shown = file
            if whole {
                // The compact diff is already on screen from before, or about to be replaced; either
                // way the whole one takes its place only when it arrives.
                if let expanded = await source?.whole(file) { shown = expanded }
                guard !Task.isCancelled, let self, self.rendered == file else { return }
                self.put(shown, newFile: newFile)
            }
            guard let rows = DiffPage.build(files: [shown]).files.first, !rows.rows.isEmpty else { return }
            let theme = DiffSyntaxTheme.current
            async let new = Self.sideText(source, shown, .new)
            async let old = Self.sideText(source, shown, .old)
            let tokens = await highlighter.highlights(for: rows, new: await new, old: await old, theme: theme)
            guard !Task.isCancelled, let self, self.rendered == file else { return }
            self.text.replace(tokens: tokens)
        }
    }

    private nonisolated static func sideText(_ source: DiffContentSource?, _ file: UnifiedDiffFile, _ side: DiffContentSource.Side) async -> String? {
        guard let source, file.body == .text || file.body == .lineEndings else { return nil }
        if side == .new, file.isDeleted { return nil }
        if side == .old, file.isNew { return nil }
        return await source.text(file, side)
    }

    private func put(_ file: UnifiedDiffFile, newFile: Bool) {
        let page = DiffPage.build(files: [file])
        text.replace(document: DiffDocument.build(page: page), keepingTokens: !newFile, newFile: newFile)
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
    /// Opens a path of the diff in the Files panel; nil where there is no checkout to open it from.
    var openFile: ((String) -> Void)?

    @Environment(KeyBindings.self) private var bindings

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

    /// Names the file the viewer is showing, and carries its status, its counts and the verbs of
    /// reading it (ADR-188): the previous and next change, the viewed mark, and a menu for the rest.
    /// It is the only header the diff has now that the body renders one file (ADR-101).
    @ViewBuilder
    private var fileBar: some View {
        PaneHeader {
            if !showTree { TreeToggleButton(isOn: $showTree) }
            if let file = browser.selectedFile {
                Text(file.path)
                    .font(.system(size: PaneMetrics.label, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
                    .help(file.path)
                    .layoutPriority(-1)
                if browser.selectionLeftDiff {
                    DiffChip(title: "no longer changed", colour: .orange)
                        .help("This file left the diff while you were reading it. Pick another file to move on.")
                } else if let status = DiffFileStatus(file) {
                    status.label
                }
                Spacer(minLength: 6)
                // The counts are the first thing to go when the column is narrow: the tree row
                // beside it already says how much changed, and the buttons cannot be said elsewhere.
                // A binary file has no lines to count; "+0 −0" over a picture says the wrong thing.
                if file.isBinary {
                    controls(file)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) { counts(file); controls(file) }
                        controls(file)
                    }
                }
            } else {
                Text(browser.isEmpty ? "No changes" : "Select a file")
                    .font(.system(size: PaneMetrics.label)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .contextMenu { fileActions }
    }

    private func counts(_ file: UnifiedDiffFile) -> some View {
        HStack(spacing: 4) {
            Text("+\(file.additions)").foregroundStyle(.green)
            Text("−\(file.deletions)").foregroundStyle(.red)
        }
        .font(.system(size: PaneMetrics.label, weight: .medium).monospacedDigit())
        .fixedSize()
        .padding(.trailing, 2)
    }

    private func controls(_ file: UnifiedDiffFile) -> some View {
        HStack(spacing: 0) {
            if browser.hasMediaSource {
                MediaSourceToggle(showsSource: $browser.showsMediaSource)
            }
            PaneIconButton(symbol: "chevron.up", help: "Previous change" + bindings.hint(.previousDiffChange)) { browser.goToChange(-1) }
            PaneIconButton(symbol: "chevron.down", help: "Next change" + bindings.hint(.nextDiffChange)) { browser.goToChange(1) }
            let viewed = browser.selected.map(browser.isViewed) ?? false
            PaneIconButton(symbol: viewed ? "checkmark.circle.fill" : "checkmark.circle",
                           help: (viewed ? "Viewed. Click to unmark" : "Mark viewed and go to the next file") + bindings.hint(.markDiffFileViewed),
                           isOn: viewed) { browser.toggleViewed() }
                .disabled(browser.selectionLeftDiff)
            PaneIconMenu(symbol: "ellipsis", help: "More") { fileActions }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var fileActions: some View {
        if browser.canShowWholeFile {
            Toggle("Show Whole File", isOn: $browser.showsWholeFile)
            Divider()
        }
        Button("Previous File") { browser.selectAdjacentFile(-1) }.disabled(!browser.canGoToFile.previous)
        Button("Next File") { browser.selectAdjacentFile(1) }.disabled(!browser.canGoToFile.next)
        if let path = browser.selectedFile?.path {
            Divider()
            if let openFile, browser.selectedFile?.isDeleted == false {
                Button("Open in Files") { openFile(path) }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
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
                Text("No matching files").font(.system(size: PaneMetrics.label)).foregroundStyle(.secondary)
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
                                    isSelected: isSelected(path),
                                    help: path,
                                    accessory: { DiffFileStat(file: browser.stats[path], viewed: browser.isViewed(path)) }) { browser.select(path) }
                }
            }
        }
    }

    private func isSelected(_ path: String) -> Bool { browser.selected == path && !browser.selectionLeftDiff }

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
                                    isSelected: !row.isDirectory && isSelected(row.path),
                                    help: row.path,
                                    accessory: {
                                        if !row.isDirectory { DiffFileStat(file: browser.stats[row.path], viewed: browser.isViewed(row.path)) }
                                    }) {
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

    /// The file's lines, or — for a file whose diff has none — what happened to it (ADR-188). An
    /// empty text view said nothing, and a binary file said "0 bytes changed" whatever had changed.
    @ViewBuilder
    private var viewer: some View {
        if let file = browser.selectedFile {
            if browser.showsMedia {
                // A picture, drawn (ADR-189): both sides when it changed, one when it arrived or left.
                DiffMediaView(browser: browser, file: file)
            } else {
                switch file.body {
                case .text:
                    DiffTextBody(source: browser.text)
                case .binary:
                    ContentUnavailableView("Binary file", systemImage: "doc.badge.gearshape",
                                           description: Text(file.isNew ? "Added. Its contents are not text, so there is nothing to compare line by line."
                                                             : file.isDeleted ? "Deleted. Its contents were not text."
                                                             : "Changed. Its contents are not text, so there is nothing to compare line by line."))
                case .renamed(let from):
                    ContentUnavailableView("Renamed, contents unchanged", systemImage: "arrow.right.doc.on.clipboard",
                                           description: Text("From \(from)"))
                case .mode(let old, let new):
                    ContentUnavailableView("Permissions changed", systemImage: "lock.open",
                                           description: Text(Self.describe(mode: old, new) + "\nIts contents are unchanged."))
                case .lineEndings:
                    ContentUnavailableView("Only line endings changed", systemImage: "return",
                                           description: Text("Every changed line has the same text as before and a different line ending (LF and CRLF)."))
                case .empty:
                    ContentUnavailableView(file.isNew ? "Empty file added" : file.isDeleted ? "Empty file deleted" : "No line changes",
                                           systemImage: "doc", description: Text(file.path))
                }
            }
        } else {
            ContentUnavailableView("Select a file", systemImage: "sidebar.left")
        }
    }

    private static func describe(mode old: String, _ new: String) -> String {
        let wasExecutable = old.hasSuffix("755"), isExecutable = new.hasSuffix("755")
        if !wasExecutable && isExecutable { return "Made executable (\(old) to \(new))." }
        if wasExecutable && !isExecutable { return "No longer executable (\(old) to \(new))." }
        return "Mode \(old) to \(new)."
    }
}

/// A small capsule beside the file's name.
struct DiffChip: View {
    let title: String
    let colour: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(colour)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(colour.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// What happened to a file, when it is not a plain edit — the one thing the tree's A/D badge cannot
/// say (it has no room for "renamed").
enum DiffFileStatus {
    case added, deleted, renamed

    init?(_ file: UnifiedDiffFile) {
        if file.isNew { self = .added }
        else if file.isDeleted { self = .deleted }
        else if file.renamedFrom != nil { self = .renamed }
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

    var label: some View { DiffChip(title: title, colour: colour) }
}

/// A changed file's own +/− count, or its A/D badge — so the list carries the shape of the change
/// and not just its paths (ADR-091). The trailing accessory of a shared file-tree row (ADR-099).
/// A file the reader has marked viewed leads with a tick (ADR-188).
struct DiffFileStat: View {
    let file: UnifiedDiffFile?
    var viewed = false

    var body: some View {
        if let file {
            HStack(spacing: 4) {
                if viewed {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
                if file.isNew {
                    Text("A").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
                } else if file.isDeleted {
                    Text("D").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                } else if file.isBinary {
                    // Changed, with no lines to count (ADR-189): a picture, usually.
                    Text("M").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                } else {
                    Text("\(file.additions + file.deletions)")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .opacity(viewed ? 0.6 : 1)
        }
    }
}
