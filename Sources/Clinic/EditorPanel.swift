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

    var showTree: Bool { didSet { UserDefaults.standard.set(showTree, forKey: Self.showTreeKey) } }

    private init() { showTree = UserDefaults.standard.object(forKey: Self.showTreeKey) as? Bool ?? true }
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
    /// False for a file window, which shows one file and never a tree.
    private let buildsTree: Bool
    /// Told when a different file is opened, so a file window can re-title itself (ADR-081).
    @ObservationIgnored var onOpen: ((String) -> Void)?

    init(root: String, tree buildsTree: Bool = true) {
        self.root = root
        self.buildsTree = buildsTree
        self.index = FileIndex(root: root)
        watch()
        Task { await reloadTree() }
    }

    /// Rebuilds the tree from the flat index (hidden entries filtered per `showHidden`).
    func reloadTree() async {
        guard buildsTree else { return }
        let files = await index.files()
        tree = FileTreeNode.build(from: files, showHidden: showHidden)
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
            language = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: path))
            fileModified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            externalChangePending = false
            error = nil
            recentlyOpened.removeAll { $0 == path }
            recentlyOpened.insert(path, at: 0)
            if recentlyOpened.count > 20 { recentlyOpened.removeLast() }
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

    func revert() { text = savedText }

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
    private var prefs: EditorPrefs { EditorPrefs.shared }

    var body: some View {
        // Both halves must claim the full height: an `HSplitView` whose children only have an ideal
        // height collapses to it and sits along the bottom edge (visible with no file open).
        HSplitView {
            if prefs.showTree {
                sidebar.frame(minWidth: 180, idealWidth: 220, maxWidth: 360, maxHeight: .infinity)
            }
            FileEditorView(model: model, showsTreeToggle: true, showsPopOut: true)
                .frame(minWidth: 320, maxHeight: .infinity)
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
            HStack(spacing: 6) {
                Text((model.root as NSString).lastPathComponent).font(.subheadline.weight(.semibold)).lineLimit(1).help(model.root)
                Spacer()
                Toggle(isOn: $model.showHidden) { Image(systemName: "eye") }.toggleStyle(.button).buttonStyle(.borderless).help("Show hidden files")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            List {
                if let id = tab.sessionId, let files = sessions.sessions[id]?.recentFiles, !files.isEmpty {
                    Section("Agent files") {
                        ForEach(files.reversed(), id: \.self) { path in
                            Label((path as NSString).lastPathComponent, systemImage: "pencil.line").lineLimit(1).help(path)
                                .contentShape(Rectangle()).onTapGesture { model.open(absolute: path) }
                                .contextMenu { FileRowMenu(path: path, root: model.root) }
                        }
                    }
                }
                Section("Files") {
                    OutlineGroup(model.tree, children: \.children) { node in
                        if node.isDirectory {
                            Label(node.name, systemImage: "folder").lineLimit(1)
                        } else {
                            Label(node.name, systemImage: FileGlyph.symbol(for: node.name)).lineLimit(1)
                                .contentShape(Rectangle())
                                .onTapGesture { model.open(relative: node.relativePath) }
                                .listRowBackground(model.relativeOpenPath == node.relativePath ? Color.accentColor.opacity(0.15) : Color.clear)
                                .contextMenu { FileRowMenu(path: (model.root as NSString).appendingPathComponent(node.relativePath), root: model.root) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
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
    @State private var editorState = SourceEditorState()
    @State private var quickOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).padding(6) }
            if model.openPath != nil {
                SourceEditor(
                    $model.text,
                    language: model.language,
                    configuration: SourceEditorConfiguration(
                        appearance: .init(theme: EditorThemes.current, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), wrapLines: false, tabWidth: 4),
                        behavior: .init(isEditable: true, indentOption: .spaces(count: 4)),
                        peripherals: .init(showGutter: true, showMinimap: false, showReformattingGuide: false, showFoldingRibbon: false)
                    ),
                    state: $editorState
                )
            } else {
                ContentUnavailableView("Pick a file", systemImage: "doc.text", description: Text("From the tree, the agent's files, or ⌘⇧O."))
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

/// Nested file tree built once from the flat index; directories first, name-sorted.
struct FileTreeNode: Identifiable, Hashable {
    let relativePath: String
    let name: String
    let isDirectory: Bool
    var children: [FileTreeNode]?
    var id: String { relativePath }

    static func build(from files: [String], showHidden: Bool) -> [FileTreeNode] {
        final class Dir { var dirs: [String: Dir] = [:]; var files: [String] = [] }
        let root = Dir()
        for f in files {
            let parts = f.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            if !showHidden && parts.contains(where: { $0.hasPrefix(".") }) { continue }
            var cur = root
            for p in parts.dropLast() { if cur.dirs[p] == nil { cur.dirs[p] = Dir() }; cur = cur.dirs[p]! }
            cur.files.append(parts.last!)
        }
        func nodes(_ d: Dir, prefix: String) -> [FileTreeNode] {
            let dirs = d.dirs.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name in
                FileTreeNode(relativePath: prefix + name, name: name, isDirectory: true, children: nodes(d.dirs[name]!, prefix: prefix + name + "/"))
            }
            let files = d.files.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { FileTreeNode(relativePath: prefix + $0, name: $0, isDirectory: false, children: nil) }
            return dirs + files
        }
        return nodes(root, prefix: "")
    }
}

enum FileGlyph {
    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "txt": return "doc.text"
        case "json", "yml", "yaml", "toml", "plist": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "sh", "fish", "zsh", "bash": return "terminal"
        default: return "doc"
        }
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
            List(Array(results.enumerated()), id: \.offset) { i, path in
                HStack {
                    Image(systemName: FileGlyph.symbol(for: path)).foregroundStyle(.secondary)
                    Text((path as NSString).lastPathComponent)
                    Text((path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    Spacer()
                }
                .listRowBackground(i == highlighted ? Color.accentColor.opacity(0.2) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { highlighted = i; openHighlighted() }
            }
            .listStyle(.plain)
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
