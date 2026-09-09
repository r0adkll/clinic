import SwiftUI
import ClinicCore
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(WindowState.self) private var window
    @Environment(KeyBindings.self) private var bindings
    @Binding var showNewSession: Bool
    @State private var query = ""

    @AppStorage("ClinicShowUsage") private var showUsage = true
    @AppStorage("ClinicShowFolderPaths") private var showFolderPaths = false

    var body: some View {
        VStack(spacing: 0) {
            MarketplaceNavRow()
            sidebarToolbar
            // The gap above the first project sits outside the scroll view on purpose: as
            // `contentMargins(for: .scrollContent)` it was applied on a later layout pass and popped
            // in on the first scroll, and as a spacer row it took the sidebar's minimum row height.
            Divider().padding(.bottom, 8)
            sessionList
            if bulkActive { Divider(); BulkActionBar(ids: bulkIds) }
            if showUsage { Divider(); UsagePanel() }
        }
    }

    /// Select mode, or a ⌘/⇧-click multi-selection (ADR-074).
    private var bulkActive: Bool { window.selectMode || window.bulkSelection.count > 1 }
    private var bulkIds: [SessionID] { Self.sessionIds(window.bulkSelection, sessions: sessions) }

    static func sessionIds(_ items: Set<SidebarItem>, sessions: SessionStore) -> [SessionID] {
        items.compactMap { if case .session(let id) = $0, sessions.sessions[id] != nil { return id } else { return nil } }
            .sorted { ($0.rawValue) < ($1.rawValue) }
    }

    /// Collapse-all / expand-all, select mode and add-project (ADR-062, ADR-074). The row carries no
    /// caption: what it sits above is a list of projects, not "Sessions" (ADR-077).
    private var sidebarToolbar: some View {
        HStack(spacing: 1) {
            Spacer(minLength: 0)
            ToolbarIcon(window.selectMode ? "checklist.checked" : "checklist",
                        help: (window.selectMode ? "Done selecting" : "Select sessions") + bindings.hint(.selectSessions),
                        active: window.selectMode) { window.selectMode.toggle() }
            ToolbarIcon("chevron.up.chevron.down", help: "Collapse all") { sessions.collapseAll() }
            ToolbarIcon("chevron.down", help: "Expand all") { sessions.expandAll() }
            Divider().frame(height: 12).padding(.horizontal, 3)
            ToolbarIcon("folder.badge.plus", help: "Add project folder") { addProject() }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder to show in the sidebar"
        if panel.runModal() == .OK, let url = panel.url { sessions.addProject(url.path) }
    }

    private var sessionList: some View {
        List(selection: selection) {
            let favorites = sessions.favoriteSessions.filter { sessions.matches($0, query: query) }
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { summary in row(summary) }
                }
            }
            ForEach(sessions.projects) { project in
                let rows = sessions.sessions(in: project).filter { sessions.matches($0, query: query) }
                let collapsed = query.isEmpty && sessions.isCollapsed(project)
                if !rows.isEmpty || query.isEmpty {
                    Section {
                        if !collapsed {
                            ForEach(rows) { summary in row(summary) }
                            if rows.isEmpty { NewSessionPlaceholderRow(project: project) }
                        }
                    } header: {
                        ProjectHeader(project: project, count: rows.count, collapsed: collapsed)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            let ids = Self.sessionIds(items, sessions: sessions)
            if ids.count > 1 { BulkSessionMenu(ids: ids) }
            else if let id = ids.first, let s = sessions.sessions[id] { SessionContextMenu(summary: s) }
        }
        .onExitCommand { if window.selectMode { window.selectMode = false } else { window.bulkSelection = [] } }
        .searchable(text: $query, placement: .sidebar, prompt: "Filter sessions")
        .overlay {
            if sessions.projects.isEmpty && !sessions.isScanning {
                ContentUnavailableView("No sessions yet", systemImage: "tray", description: Text("Start one with ⌘N, or import an existing session with ⌘K."))
            }
        }
    }

    @ViewBuilder
    private func row(_ summary: SessionSummary) -> some View {
        let item = SidebarItem.session(summary.id)
        SessionRow(summary: summary, tab: tabs.tab(for: summary.id), showPath: showFolderPaths,
                   checked: window.selectMode ? window.bulkSelection.contains(item) : nil,
                   onToggle: { if window.bulkSelection.contains(item) { window.bulkSelection.remove(item) } else { window.bulkSelection.insert(item) } })
            .tag(item)
    }
}

/// The Marketplace navigation row, pinned above the project list and its toolbar (ADR-084).
/// It sits outside the `List` on purpose: it is a destination, not a session, so it takes no
/// `SidebarItem` and never competes with the list's selection.
struct MarketplaceNavRow: View {
    @Environment(WindowState.self) private var window
    @Environment(KeyBindings.self) private var bindings
    @State private var hovering = false

    private var active: Bool { window.showingMarketplace }

    var body: some View {
        Button { window.showingMarketplace = true } label: {
            HStack(spacing: 6) {
                // Reserves the disclosure column a project header uses, so the icon lands in the same
                // glyph column as a project's icon and the label under the same left edge (ADR-077).
                Color.clear.frame(width: 12, height: 12)
                // Keeps the header's 22 pt glyph *column* for alignment, but only the glyph's own
                // height: a project header is 22 pt tall because its icon is, and this row is not.
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 13))
                    .frame(width: 22, height: 16)
                Text("Marketplace").font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
            }
            .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Find and install Claude Code plugins" + bindings.hint(.marketplace))
        .padding(.horizontal, 10).padding(.top, 4)
    }

    private var background: AnyShapeStyle {
        if active { return AnyShapeStyle(Color.accentColor) }
        return hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
    }
}

/// Stable selection identity: sessions by id (open or not), shells by tab id.
enum SidebarItem: Hashable {
    case session(SessionID)
    case tab(UUID)
}

extension SidebarView {
    /// Plain click opens one session; ⌘/⇧-click or select mode builds a multi-selection instead (ADR-074).
    var selection: Binding<Set<SidebarItem>> {
        Binding(
            get: {
                if window.selectMode || window.bulkSelection.count > 1 { return window.bulkSelection }
                guard let tab = tabs.selectedTab(in: window) else { return [] }
                return [tab.sessionId.map(SidebarItem.session) ?? .tab(tab.id)]
            },
            set: { items in
                if window.selectMode || items.count > 1 { window.bulkSelection = items; return }
                // ⌘-clicking a multi-selection down to one row is a deselect, not an open.
                if window.bulkSelection.count > 1, items.isSubset(of: window.bulkSelection) { window.bulkSelection = []; return }
                window.bulkSelection = []
                switch items.first {
                case .session(let id)?:
                    if let tab = tabs.tab(for: id) { tabs.select(tab) }
                    else if let summary = sessions.sessions[id] { tabs.open(session: summary) }
                case .tab(let id)?:
                    if let tab = tabs.tabs.first(where: { $0.id == id }) { tabs.select(tab) }
                case nil:
                    break
                }
            })
    }
}

/// Bulk actions over several sessions (ADR-074). Archive runs the per-session flow (tab close confirmation, worktree offer).
@MainActor
enum BulkSessionActions {
    static func open(_ ids: [SessionID], sessions: SessionStore, tabs: TabStore) {
        for id in ids { if let s = sessions.sessions[id] { tabs.open(session: s) } }
    }
    static func closeTabs(_ ids: [SessionID], tabs: TabStore) {
        for id in ids { if let t = tabs.tab(for: id) { tabs.close(t) } }
    }
    static func allFavorites(_ ids: [SessionID], sessions: SessionStore) -> Bool { !ids.isEmpty && ids.allSatisfy { sessions.isFavorite($0) } }
    static func toggleFavorites(_ ids: [SessionID], sessions: SessionStore) {
        let remove = allFavorites(ids, sessions: sessions)
        sessions.update { s in for id in ids { if remove { s.favorites.remove(id) } else { s.favorites.insert(id) } } }
    }
    static func allMuted(_ ids: [SessionID], sessions: SessionStore) -> Bool { !ids.isEmpty && ids.allSatisfy { sessions.state.mutedSessions.contains($0) } }
    static func toggleMute(_ ids: [SessionID], sessions: SessionStore) {
        let unmute = allMuted(ids, sessions: sessions)
        sessions.update { s in for id in ids { if unmute { s.mutedSessions.remove(id) } else { s.mutedSessions.insert(id) } } }
    }
    static func archive(_ ids: [SessionID], sessions: SessionStore, tabs: TabStore, window: WindowState) {
        for id in ids { if let s = sessions.sessions[id], !sessions.isArchived(id) { SessionActions.archive(s, sessions: sessions, tabs: tabs) } }
        window.bulkSelection = []
    }
    static func openCount(_ ids: [SessionID], tabs: TabStore) -> Int { ids.filter { tabs.tab(for: $0) != nil }.count }
}

struct BulkSessionMenu: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(WindowState.self) private var window
    let ids: [SessionID]

    var body: some View {
        Button("Open \(ids.count) Sessions") { BulkSessionActions.open(ids, sessions: sessions, tabs: tabs) }
        Button("Close Tabs") { BulkSessionActions.closeTabs(ids, tabs: tabs) }.disabled(BulkSessionActions.openCount(ids, tabs: tabs) == 0)
        Divider()
        Button(BulkSessionActions.allFavorites(ids, sessions: sessions) ? "Remove from Favorites" : "Add to Favorites") { BulkSessionActions.toggleFavorites(ids, sessions: sessions) }
        Button(BulkSessionActions.allMuted(ids, sessions: sessions) ? "Unmute Notifications" : "Mute Notifications") { BulkSessionActions.toggleMute(ids, sessions: sessions) }
        Button("Archive \(ids.count) Sessions") { BulkSessionActions.archive(ids, sessions: sessions, tabs: tabs, window: window) }
    }
}

/// Bottom bar in select mode / with a multi-selection: count plus the bulk actions.
struct BulkActionBar: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(WindowState.self) private var window
    let ids: [SessionID]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ids.isEmpty ? "Select sessions" : "\(ids.count) selected").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { window.selectMode = false; window.bulkSelection = [] }.font(.caption)
            }
            HStack(spacing: 6) {
                Button("Open") { BulkSessionActions.open(ids, sessions: sessions, tabs: tabs) }
                Button("Close") { BulkSessionActions.closeTabs(ids, tabs: tabs) }.disabled(BulkSessionActions.openCount(ids, tabs: tabs) == 0)
                Button(BulkSessionActions.allFavorites(ids, sessions: sessions) ? "Unstar" : "Star") { BulkSessionActions.toggleFavorites(ids, sessions: sessions) }
                Button(BulkSessionActions.allMuted(ids, sessions: sessions) ? "Unmute" : "Mute") { BulkSessionActions.toggleMute(ids, sessions: sessions) }
                Button("Archive") { BulkSessionActions.archive(ids, sessions: sessions, tabs: tabs, window: window) }
            }
            .controlSize(.small)
            .disabled(ids.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct SessionContextMenu: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(BackgroundAgentsService.self) private var background
    let summary: SessionSummary

    var body: some View {
        let agent = background.agent(for: summary.id)
        Button(agent?.isRunning == true ? "Attach" : "Open") { tabs.open(session: summary) }
        if let tab = tabs.tab(for: summary.id) {
            Button("Close Tab") { tabs.close(tab) }
            if tab.isRunningClaude { Button("Stop") { tabs.stop(tab) } }
            if tab.state == .idle { Button("Background") { tabs.background(tab) } }
        }
        Button("Fork Session") { tabs.fork(summary) }
        if let tab = tabs.tab(for: summary.id) { MoveToWindowMenu(tab: tab) }
        if TabStore.ghosttyBinary != nil { Button("Open in Ghostty") { tabs.openInGhostty(summary) } }
        OpenInMenu(path: summary.lastCwd ?? summary.cwd ?? "")
        if let agent {
            Divider()
            if agent.isRunning { Button("Stop Detached Session") { Task { await background.stopAgent(agent) } } }
            Button("Show Logs") { tabs.newShell(in: summary.lastCwd ?? summary.cwd, initialInput: "claude logs \(agent.id)\n") }
            Button("Remove Detached Session", role: .destructive) { Task { await background.removeAgent(agent) } }
        }
        Button("Replay…") { tabs.openReplay(summary) }
        Button("Details…") { NotificationCenter.default.post(name: .clinicSessionDetails, object: summary.id.rawValue) }
        Divider()
        Button("Rename…") { SessionActions.rename(summary, sessions: sessions) }
        if sessions.state.manualNames[summary.id] != nil { Button("Clear Custom Name") { sessions.rename(summary.id, to: nil) } }
        Button(sessions.isFavorite(summary.id) ? "Remove from Favorites" : "Add to Favorites") { sessions.toggleFavorite(summary.id) }
        Button(sessions.state.mutedSessions.contains(summary.id) ? "Unmute Notifications" : "Mute Notifications") {
            sessions.update { s in if s.mutedSessions.contains(summary.id) { s.mutedSessions.remove(summary.id) } else { s.mutedSessions.insert(summary.id) } }
        }
        if sessions.isArchived(summary.id) {
            Button("Unarchive") { sessions.unarchive(summary.id) }
        } else {
            Button("Archive") { SessionActions.archive(summary, sessions: sessions, tabs: tabs) }
        }
        Divider()
        Button("Copy Session ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary.id.rawValue, forType: .string) }
        Button("Reveal Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.transcriptPath)]) }
        Button("Export as Markdown…") { SessionActions.exportMarkdown(summary, sessions: sessions) }
    }
}

/// "Open In…" submenu: Finder, Ghostty, and installed editors, each with its app icon (ADR-063, ADR-078).
struct OpenInMenu: View {
    let path: String
    private var apps: OpenInApps { OpenInApps.shared }

    var body: some View {
        Menu("Open In") {
            ForEach(apps.targets) { target in
                OpenInRow(target: target) { apps.open(path, in: target) }
            }
        }
        .disabled(path.isEmpty)
        .onAppear { apps.refreshIfStale() }
    }
}

@MainActor
enum SessionActions {
    static func rename(_ summary: SessionSummary, sessions: SessionStore) {
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "The name is stored by Clinic only; Claude Code's own title is unchanged."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = sessions.state.manualNames[summary.id] ?? sessions.displayName(for: summary)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { sessions.rename(summary.id, to: field.stringValue) }
    }

    static func exportMarkdown(_ summary: SessionSummary, sessions: SessionStore) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sessions.displayName(for: summary).replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = summary.transcriptPath, title = sessions.displayName(for: summary)
        Task.detached {
            guard let r = try? TranscriptTurns.read(fileAt: path) else { return }
            try? TranscriptTurns.markdown(r, title: title).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Archiving an open session closes its tab first (with the usual confirmation if Claude is running), then offers to trash its worktree (ADR-065).
    static func archive(_ summary: SessionSummary, sessions: SessionStore, tabs: TabStore) {
        if let tab = tabs.tab(for: summary.id), !tabs.close(tab) { return }
        Task { @MainActor in
            let trashed = await RepoUpkeep.offerWorktreeTrash(for: summary, tabs: tabs, agents: tabs.backgroundAgents)
            sessions.archive(summary.id, trashedWorktree: trashed)
        }
    }
}

struct SessionRow: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs
    @Environment(BackgroundAgentsService.self) private var background
    let summary: SessionSummary
    let tab: Tab?
    var showPath = false
    /// Non-nil in select mode: shows a checkbox (ADR-074).
    var checked: Bool? = nil
    var onToggle: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let checked {
                Button(action: onToggle) {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle").foregroundStyle(checked ? Color.accentColor : Color.secondary)
                }.buttonStyle(.plain)
            }
            if let tab, tab.isAttached, !tab.childExited {
                Image(systemName: "moon.zzz.fill").font(.caption).foregroundStyle(Color.accentColor).frame(width: 10)
                    .help("Attached to a detached session (state not reported)")
            } else if tab == nil, let agent = background.agent(for: summary.id), agent.isRunning {
                Image(systemName: agent.needsAttention ? "exclamationmark.circle.fill" : "moon.zzz.fill")
                    .font(.caption).foregroundStyle(agent.needsAttention ? .orange : .secondary).frame(width: 10)
                    .help(agent.needsAttention ? "Detached — needs you" : "Running detached (\(agent.state ?? agent.status))")
            } else {
                StateGlyph(tab: tab)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(sessions.displayName(for: summary)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(summary.activityDate, format: .relative(presentation: .named))
                    if showPath, let cwd = summary.lastCwd ?? summary.cwd {
                        Text("·"); Text(TabFooter.abbreviate(cwd)).lineLimit(1).truncationMode(.head)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hovering { hoverActions } else { badges }
        }
        .padding(.vertical, 3)
        .opacity(sessions.isArchived(summary.id) ? 0.5 : 1)
        .onHover { hovering = $0 }
    }

    /// Trailing hover actions (ADR-077). They replace the badges rather than the timestamp, so the
    /// row keeps its size, and they carry no colour of their own so a selected row stays readable.
    @ViewBuilder
    private var hoverActions: some View {
        let archived = sessions.isArchived(summary.id), starred = sessions.isFavorite(summary.id)
        HStack(spacing: 0) {
            if let tab, tab.isRunningClaude { RowAction("stop.fill", help: "Stop") { tabs.stop(tab) } }
            if let tab { RowAction("xmark", help: "Close Tab") { tabs.close(tab) } }
            RowAction(starred ? "star.slash" : "star", help: starred ? "Remove from Favorites" : "Add to Favorites") {
                sessions.toggleFavorite(summary.id)
            }
            RowAction(archived ? "tray.and.arrow.up" : "archivebox", help: archived ? "Unarchive" : "Archive") {
                if archived { sessions.unarchive(summary.id) } else { SessionActions.archive(summary, sessions: sessions, tabs: tabs) }
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            PRMarkView(refs: summary.pullRequests)
            if sessions.state.mutedSessions.contains(summary.id) { Image(systemName: "bell.slash").font(.caption).foregroundStyle(.tertiary) }
            if sessions.isFavorite(summary.id) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
        }
    }
}

/// One trailing action on a session row. Deliberately unstyled: on a selected sidebar row the
/// glyph inherits the selection's own label colour, which accent-coloured text did not (ADR-077).
struct RowAction: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    init(_ systemName: String, help: String, action: @escaping () -> Void) {
        self.systemName = systemName; self.help = help; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// A sidebar toolbar glyph: secondary until hovered, accent while its mode is on.
struct ToolbarIcon: View {
    let systemName: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    init(_ systemName: String, help: String, active: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName; self.help = help; self.active = active; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(hovering ? HierarchicalShapeStyle.primary : .secondary))
                .frame(width: 22, height: 20)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// ADR-040 glyphs, system semantic colors only.
struct StateGlyph: View {
    let tab: Tab?
    @State private var pulse = false

    var body: some View {
        Group {
            if let tab {
                if tab.unread {
                    Circle().fill(Color.accentColor)
                } else {
                    switch tab.state {
                    case .working, .launching:
                        Circle().fill(Color.accentColor).opacity(pulse ? 0.35 : 1)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                            .onAppear { pulse = true }
                    case .waitingForPermission, .waitingForInput:
                        Circle().fill(Color.orange)
                    case .idle:
                        Circle().fill(Color.secondary)
                    case .exited:
                        Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                    case nil:
                        Circle().fill(Color.secondary)
                    }
                }
            } else {
                Circle().fill(.clear)
            }
        }
        .frame(width: 10, height: 10)
        .help(helpText)
    }

    private var helpText: String {
        guard let tab else { return "Not open" }
        if tab.unread { return "Finished — unread" }
        switch tab.state {
        case .launching: return "Starting"
        case .working: return "Working"
        case .waitingForPermission: return "Waiting for permission"
        case .waitingForInput: return "Waiting for your input"
        case .idle: return "Idle at the prompt"
        case .exited: return "Exited"
        case nil: return "Shell"
        }
    }
}
