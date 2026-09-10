import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import ClinicCore

/// Layout choices the Files panes and file windows share (ADR-081). Held in one observable object so
/// hiding the tree in one pane hides it in every other, and persisted: it says how you read code, not
/// how one pane is arranged.
@MainActor
@Observable
final class EditorPrefs {
    static let shared = EditorPrefs()
    static let showTreeKey = "ClinicEditorShowTree"
    static let treeWidthKey = "ClinicEditorTreeWidth"

    var showTree: Bool { didSet { UserDefaults.standard.set(showTree, forKey: Self.showTreeKey) } }
    /// The tree column's width, as the user last dragged it.
    var treeWidth: CGFloat { didSet { UserDefaults.standard.set(Double(treeWidth), forKey: Self.treeWidthKey) } }

    private init() {
        showTree = UserDefaults.standard.object(forKey: Self.showTreeKey) as? Bool ?? true
        let stored = UserDefaults.standard.double(forKey: Self.treeWidthKey)
        treeWidth = stored > 0 ? CGFloat(stored) : 180
    }

    static let minTreeWidth: CGFloat = 160
    static let maxTreeWidth: CGFloat = 480

    /// Never below the minimum, never past the maximum, and never leaving the code view under 300 pt.
    static func clamp(_ width: CGFloat, available: CGFloat) -> CGFloat {
        let upper = max(minTreeWidth, min(maxTreeWidth, available - 300))
        return min(max(width, minTreeWidth), upper)
    }
}

/// Per-tab editor state (ADR-057): root, index, open file, dirty flag, external-change watch.
/// A file window (ADR-081) uses one too, with `tree: false`: it indexes for quick open but builds no tree.
@MainActor
@Observable
final class EditorModel {
    private(set) var root: String
    private(set) var index: FileIndex
    var openPath: String?            // absolute
    var text = ""
    var savedText = ""
    var language: CodeLanguage = .default
    var isDirty: Bool { text != savedText }
    var error: String?
    var showHidden = false { didSet { Task { await reloadTree() } } }
    var externalChangePending = false
    private var watcher: FSEventsWatcher?
    private var watchTask: Task<Void, Never>?
    private var fileModified: Date?
    var recentlyOpened: [String] = []
    private(set) var tree: [FileTreeNode] = []
    /// Directories the user has opened. Held in the model rather than inside the outline view for two
    /// reasons (ADR-099): the tree is rebuilt from scratch on every FSEvents burst, and a save must
    /// not collapse the folders you were reading; and opening a file from anywhere reveals it by
    /// expanding its ancestors, which needs somewhere to write that down.
    private(set) var expandedDirectories: Set<String> = []
    /// False for a file window, which shows one file and never a tree.
    private let buildsTree: Bool
    /// Told when a different file is opened, so a file window can re-title itself (ADR-081).
    @ObservationIgnored var onOpen: ((String) -> Void)?
    /// Bumped every time the buffer is replaced from disk (open, reload, revert). `SourceEditor` only
    /// reads its text binding when its controller is made — `updateNSViewController` never pushes text
    /// back — so the code view's identity is this counter, and a load rebuilds it (ADR-081).
    private(set) var loadGeneration = 0

    init(root: String, tree buildsTree: Bool = true) {
        self.root = root
        self.buildsTree = buildsTree
        self.index = FileIndex(root: root)
        watch()
        Task { await reloadTree() }
    }

    /// Rebuilds the tree from the flat index (hidden entries filtered per `showHidden`).
    ///
    /// Built off the main actor: this runs on every debounced FSEvents burst, and a 50 000-entry
    /// index is a real pass over a real amount of memory to do while the terminal next door is
    /// drawing.
    func reloadTree() async {
        guard buildsTree else { return }
        let files = await index.files()
        let hidden = showHidden
        tree = await Task.detached(priority: .userInitiated) {
            FileTreeNode.build(from: files, showHidden: hidden)
        }.value
    }

    /// The flat rows the tree draws (ADR-099). Cheap on every redraw: it descends only into open
    /// directories, so a collapsed repo costs one pass over its top level.
    var visibleRows: [FileTreeRow] { FileTreeNode.rows(tree, expanded: expandedDirectories) }

    func toggle(directory path: String) {
        if expandedDirectories.contains(path) { expandedDirectories.remove(path) } else { expandedDirectories.insert(path) }
    }

    func collapseAll() { expandedDirectories.removeAll() }

    /// Opens every folder above `path`, so a file opened from Quick Open, the agent's list or another
    /// pane is where the reader can see it in the tree.
    private func reveal(_ path: String) {
        guard path.hasPrefix(root + "/") else { return }
        expandedDirectories.formUnion(FileTreeNode.ancestors(of: String(path.dropFirst(root.count + 1))))
    }

    func rebind(root newRoot: String) {
        guard newRoot != root else { return }
        root = newRoot
        index = FileIndex(root: newRoot)
        watchTask?.cancel(); watcher?.stop()
        watch()
        Task { await reloadTree() }
    }

    private func watch() {
        let w = FSEventsWatcher(paths: [root])
        watcher = w
        w.start()
        watchTask = Task { [weak self] in
            for await paths in w.changes {
                guard let self else { return }
                await self.index.invalidate()
                await self.reloadTree()
                if let open = self.openPath, paths.contains(where: { $0 == open || open.hasPrefix($0) }) { self.externalChanged() }
            }
        }
    }

    func stop() { watchTask?.cancel(); watcher?.stop() }

    func open(relative: String) { open(absolute: (root as NSString).appendingPathComponent(relative)) }

    func open(absolute path: String) {
        if isDirty, let current = openPath, current != path, !confirmDiscard() { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard data.count < 8 * 1024 * 1024 else { error = "File is larger than 8 MB"; return }
            guard let s = String(data: data, encoding: .utf8) else { error = "Not a UTF-8 text file"; return }
            text = s; savedText = s
            openPath = path
            reveal(path)
            language = FileLanguage.detect(path: path, text: s)
            fileModified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            externalChangePending = false
            error = nil
            recentlyOpened.removeAll { $0 == path }
            recentlyOpened.insert(path, at: 0)
            if recentlyOpened.count > 20 { recentlyOpened.removeLast() }
            loadGeneration += 1
            onOpen?(path)
        } catch { self.error = "\(error)" }
    }

    func save() {
        guard let path = openPath else { return }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            savedText = text
            fileModified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            externalChangePending = false
            error = nil
        } catch { self.error = "\(error)" }
    }

    func revert() { text = savedText; loadGeneration += 1 }

    private func externalChanged() {
        guard let path = openPath else { return }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        guard mtime != fileModified else { return }
        if isDirty { externalChangePending = true } else { reloadFromDisk() }
    }

    func reloadFromDisk() {
        guard let path = openPath, let s = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        text = s; savedText = s
        fileModified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        externalChangePending = false
        loadGeneration += 1
    }

    private func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = (openPath as NSString?)?.lastPathComponent ?? ""
        alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var relativeOpenPath: String? {
        guard let p = openPath else { return nil }
        return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p
    }
}

/// Right-column Files pane: an optional file tree beside the shared code view (ADR-057, ADR-081).
struct EditorPanel: View {
    @Environment(SessionStore.self) private var sessions
    let tab: Tab
    @Bindable var model: EditorModel
    /// The live column width. Held here rather than read from `EditorPrefs` on every frame: the drag
    /// writes it many times a second, and only its final value is worth persisting.
    @State private var treeWidth = EditorPrefs.shared.treeWidth
    private var prefs: EditorPrefs { EditorPrefs.shared }

    /// The width the tree may take in a pane this wide. Clamping here rather than when the drag stores
    /// it means a narrow panel borrows from the tree and gives it back when it widens.
    private func clamped(_ width: CGFloat, in available: CGFloat) -> CGFloat {
        EditorPrefs.clamp(width, available: available)
    }

    var body: some View {
        // A fixed-width tree column and a drag handle, not an `HSplitView`: the split view hands its
        // first child the *maximum* its frame allows and ignores `idealWidth`, so a remembered width
        // can be neither applied nor read back through it (ADR-081).
        GeometryReader { geo in
            let width = clamped(treeWidth, in: geo.size.width)
            HStack(spacing: 0) {
                if prefs.showTree {
                    sidebar.frame(width: width)
                    TreeResizeHandle(width: $treeWidth, base: width, available: geo.size.width)
                }
                FileEditorView(model: model, showsTreeToggle: true, showsPopOut: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: tab.pwd) {
            let dir = tab.pwd ?? tab.projectPath
            var root = dir
            if let repo = await GitRepository.discover(from: dir) { root = repo.root }
            model.rebind(root: root)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text((model.root as NSString).lastPathComponent).font(.subheadline.weight(.semibold)).lineLimit(1).help(model.root)
                Spacer(minLength: 4)
                Button { model.collapseAll() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(.borderless).help("Collapse all folders")
                    .disabled(model.expandedDirectories.isEmpty)
                Toggle(isOn: $model.showHidden) { Image(systemName: "eye") }.toggleStyle(.button).buttonStyle(.borderless).help("Show hidden files")
            }
            .controlSize(.small)
            .padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            // A flat list of rows rather than an `OutlineGroup` (ADR-099): the outline hands its
            // content closure a view only as wide as the label, so the rest of the column was dead
            // space, and its expansion state was out of reach of both the FSEvents rebuild and
            // "reveal the file I just opened".
            ScrollViewReader { proxy in
                FileTreeScroll {
                    agentFiles
                    FileTreeSectionHeader("Files", top: agentFilesCount == 0 ? 2 : 12)
                    if model.visibleRows.isEmpty {
                        Text("No files").font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 6).frame(height: FileTreeMetrics.rowHeight)
                    }
                    ForEach(model.visibleRows) { row in treeRow(row) }
                }
                // `open` expands the folders above the file; this is the other half of revealing it.
                .onChange(of: model.openPath) {
                    guard let rel = model.relativeOpenPath else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(rel, anchor: .center) }
                }
            }
        }
    }

    private var agentFilesCount: Int {
        guard let id = tab.sessionId else { return 0 }
        return sessions.sessions[id]?.recentFiles.count ?? 0
    }

    /// The files this session's agent has touched, above the tree (ADR-057).
    @ViewBuilder
    private var agentFiles: some View {
        if let id = tab.sessionId, let files = sessions.sessions[id]?.recentFiles, !files.isEmpty {
            FileTreeSectionHeader("Agent files", top: 2)
            ForEach(files.reversed(), id: \.self) { path in
                FileTreeRowView(name: (path as NSString).lastPathComponent,
                                symbol: "pencil.line",
                                isSelected: model.openPath == path,
                                help: path) { model.open(absolute: path) }
                    .contextMenu { FileRowMenu(path: path, root: model.root) }
            }
        }
    }

    /// A tap anywhere on the row acts: a folder opens or closes, a file opens. The chevron is a
    /// state indicator, not the only way in.
    private func treeRow(_ row: FileTreeRow) -> some View {
        FileTreeRowView(name: row.name,
                        depth: row.depth,
                        symbol: row.isDirectory ? (row.isExpanded ? "folder.fill" : "folder") : FileGlyph.symbol(for: row.name),
                        isExpanded: row.isDirectory ? row.isExpanded : nil,
                        isSelected: !row.isDirectory && model.relativeOpenPath == row.path,
                        help: row.path) {
            if row.isDirectory { model.toggle(directory: row.path) } else { model.open(relative: row.path) }
        }
        .id(row.path)
        .contextMenu { FileRowMenu(path: (model.root as NSString).appendingPathComponent(row.path), root: model.root) }
    }
}

/// The draggable seam between the tree and the code view (ADR-081).
///
/// The gesture measures in **global** space. The handle moves as it is dragged, so a `.local`
/// translation is taken against an origin that has just moved and the column chases the pointer —
/// which is exactly how the first version of this behaved.
private struct TreeResizeHandle: View {
    @Binding var width: CGFloat
    /// The width actually on screen when the drag starts (the stored width may be clamped smaller).
    let base: CGFloat
    let available: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .pointerStyle(.columnResize)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let from = start ?? base
                    if start == nil { start = from }
                    width = EditorPrefs.clamp(from + value.translation.width, available: available)
                }
                .onEnded { _ in
                    start = nil
                    EditorPrefs.shared.treeWidth = width.rounded()
                }
        )
    }
}

/// Context menu shared by the tree rows and the agent-files list (ADR-081).
struct FileRowMenu: View {
    let path: String
    let root: String

    var body: some View {
        Button("Open in New Window") { FileWindowController.show(path: path, root: root) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
    }
}

/// The code view and its header: the right half of the Files pane, and the whole of a file window
/// (ADR-081). Quick open and the external-change prompt live here, so both hosts get them.
struct FileEditorView: View {
    @Bindable var model: EditorModel
    /// The panel shows the tree toggle and the pop-out; a file window is already popped out and has no tree.
    var showsTreeToggle = false
    var showsPopOut = false
    @State private var quickOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).padding(6) }
            if model.openPath != nil {
                CodeView(model: model).id(model.loadGeneration)
            } else {
                // Without a filling frame the VStack shrinks to its ideal height and the whole pane —
                // toolbar included — floats in the middle of the panel (ADR-081).
                ContentUnavailableView("Pick a file", systemImage: "doc.text", description: Text("From the tree, the agent's files, or ⌘⇧O."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $quickOpen) { QuickOpenSheet(model: model) }
        .alert("File changed on disk", isPresented: $model.externalChangePending) {
            Button("Reload") { model.reloadFromDisk() }
            Button("Keep mine", role: .cancel) { model.externalChangePending = false }
        } message: { Text("You have unsaved edits to \((model.openPath as NSString?)?.lastPathComponent ?? "this file").") }
    }

    /// The header is on screen in both tree states, so the tree toggle can never hide itself.
    private var header: some View {
        HStack(spacing: 8) {
            if showsTreeToggle {
                Button { EditorPrefs.shared.showTree.toggle() } label: {
                    Image(systemName: EditorPrefs.shared.showTree ? "sidebar.left" : "sidebar.leading")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(EditorPrefs.shared.showTree ? Color.accentColor : Color.secondary)
                .help(EditorPrefs.shared.showTree ? "Hide the file tree (⌘⌃E)" : "Show the file tree (⌘⌃E)")
            }
            Button { quickOpen = true } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Quick open (⌘⇧O)").keyboardShortcut("o", modifiers: [.command, .shift])
            if let rel = model.relativeOpenPath {
                Text(rel).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.head)
                if model.isDirty { Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("Unsaved changes") }
                Text(model.language.tsName).font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("No file open").foregroundStyle(.secondary)
            }
            Spacer()
            if let path = model.openPath {
                Button("Revert") { model.revert() }.disabled(!model.isDirty)
                Button("Save") { model.save() }.keyboardShortcut("s", modifiers: .command).disabled(!model.isDirty)
                if showsPopOut {
                    Button { FileWindowController.show(path: path, root: model.root) } label: { Image(systemName: "macwindow") }
                        .help("Open this file in its own window")
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "folder") }
                    .help("Reveal in Finder")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }
}

/// The text view. Its identity is the model's `loadGeneration`, so opening, reloading or reverting a
/// file rebuilds it — `SourceEditor` reads its text binding only when its controller is made, and
/// would otherwise go on showing the buffer it was born with (ADR-081). Rebuilding also resets the
/// cursor, scroll and undo stack, which belonged to the file that just went away.
private struct CodeView: View {
    @Bindable var model: EditorModel
    @State private var editorState = SourceEditorState()
    /// Held for the life of this view: a fresh provider on every body would make the editor drop and
    /// redo all of its highlighting each update.
    @State private var markdown = MarkdownHighlighter()

    var body: some View {
        SourceEditor(
            $model.text,
            language: model.language,
            configuration: SourceEditorConfiguration(
                appearance: .init(theme: EditorThemes.current, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), wrapLines: false, tabWidth: 4),
                behavior: .init(isEditable: true, indentOption: .spaces(count: 4)),
                peripherals: .init(showGutter: true, showMinimap: false, showReformattingGuide: false, showFoldingRibbon: false)
            ),
            state: $editorState,
            highlightProviders: model.language.id == .markdown ? [markdown] : nil
        )
    }
}

/// ⌘⇧O: fuzzy file search over the index.
struct QuickOpenSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var files: [String] = []
    @State private var results: [String] = []
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Open file", text: $query).textFieldStyle(.plain).font(.title3).padding(12).focused($focused)
                .onSubmit { openHighlighted() }
                .onChange(of: query) { rank() }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Divider()
            // Same row as the tree and the pull request list (ADR-099), so a result is a full-width
            // target here too — and the arrow keys now scroll their pick into view.
            ScrollViewReader { proxy in
                FileTreeScroll {
                    ForEach(Array(results.enumerated()), id: \.offset) { i, path in
                        FileTreeRowView(name: (path as NSString).lastPathComponent,
                                        subtitle: (path as NSString).deletingLastPathComponent,
                                        symbol: FileGlyph.symbol(for: path),
                                        isSelected: i == highlighted,
                                        help: path) { highlighted = i; openHighlighted() }
                            .id(i)
                    }
                }
                .onChange(of: highlighted) { proxy.scrollTo(highlighted, anchor: .center) }
            }
        }
        .frame(width: 560, height: 400)
        .task { files = await model.index.files(); rank(); focused = true }
    }

    private func rank() {
        results = FuzzyMatcher.rank(query, candidates: files, limit: 40).map(\.candidate)
        highlighted = 0
    }

    private func openHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        model.open(relative: results[highlighted])
        dismiss()
    }
}

/// Editor colours from system semantic colours so the panel follows light/dark. Every colour is resolved to sRGB:
/// CodeEdit reads RGB components, which macOS dynamic (catalog) colours refuse with NSInvalidArgumentException.
enum EditorThemes {
    static var current: EditorTheme {
        let appearance = NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        func c(_ light: String, _ darkHex: String) -> NSColor { NSColor(hex: dark ? darkHex : light) }
        func rgb(_ color: NSColor, fallback: NSColor) -> NSColor {
            var out = fallback
            appearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? fallback }
            return out
        }
        let text = rgb(.textColor, fallback: dark ? .white : .black)
        return EditorTheme(
            text: .init(color: text),
            insertionPoint: text,
            invisibles: .init(color: rgb(.tertiaryLabelColor, fallback: .gray)),
            background: rgb(.textBackgroundColor, fallback: dark ? NSColor(hex: "#1E1E1E") : .white),
            lineHighlight: text.withAlphaComponent(0.04),
            selection: rgb(.selectedTextBackgroundColor, fallback: NSColor(hex: dark ? "#3A5070" : "#B4D5FE")),
            keywords: .init(color: c("#9B2393", "#FC5FA3"), bold: true),
            commands: .init(color: c("#326D74", "#67B7A4")),
            types: .init(color: c("#0B4F79", "#5DD8FF")),
            attributes: .init(color: c("#815F03", "#D0A8FF")),
            variables: .init(color: c("#3E8087", "#41A1C0")),
            values: .init(color: c("#6C36A9", "#A167E6")),
            numbers: .init(color: c("#1C00CF", "#D0BF69")),
            strings: .init(color: c("#C41A16", "#FC6A5D")),
            characters: .init(color: c("#1C00CF", "#D0BF69")),
            comments: .init(color: c("#5D6C79", "#6C7986"), italic: true)
        )
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
