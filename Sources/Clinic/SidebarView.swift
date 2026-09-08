import SwiftUI
import ClinicCore

struct SidebarView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Binding var showNewSession: Bool
    @State private var query = ""

    @AppStorage("ClinicShowUsage") private var showUsage = true

    var body: some View {
        VStack(spacing: 0) {
            sessionList
            if showUsage { Divider(); UsagePanel() }
        }
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
                if !rows.isEmpty || query.isEmpty {
                    Section {
                        ForEach(rows) { summary in row(summary) }
                    } header: {
                        ProjectHeader(project: project, count: rows.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Filter sessions")
        .overlay {
            if sessions.projects.isEmpty && !sessions.isScanning {
                ContentUnavailableView("No sessions yet", systemImage: "tray", description: Text("Start one with ⌘N, or import an existing session with ⌘K."))
            }
        }
    }

    @ViewBuilder
    private func row(_ summary: SessionSummary) -> some View {
        SessionRow(summary: summary, tab: tabs.tab(for: summary.id))
            .tag(SidebarItem.session(summary.id))
            .contextMenu { SessionContextMenu(summary: summary) }
    }
}

/// Stable selection identity: sessions by id (open or not), shells by tab id.
enum SidebarItem: Hashable {
    case session(SessionID)
    case tab(UUID)
}

extension SidebarView {
    var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                guard let tab = tabs.selectedTab else { return nil }
                if let id = tab.sessionId { return .session(id) }
                return .tab(tab.id)
            },
            set: { item in
                switch item {
                case .session(let id)?:
                    if let tab = tabs.tab(for: id) { tabs.selectedTabId = tab.id }
                    else if let summary = sessions.sessions[id] { tabs.open(session: summary) }
                case .tab(let id)?:
                    tabs.selectedTabId = id
                case nil:
                    break
                }
            })
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
            if tab.state == .idle { Button("Background") { tabs.background(tab) } }
        }
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

    /// Archiving an open session closes its tab first (with the usual confirmation if Claude is running).
    static func archive(_ summary: SessionSummary, sessions: SessionStore, tabs: TabStore) {
        if let tab = tabs.tab(for: summary.id), !tabs.close(tab) { return }
        sessions.archive(summary.id)
    }
}

struct SessionRow: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs
    @Environment(BackgroundAgentsService.self) private var background
    let summary: SessionSummary
    let tab: Tab?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(sessions.displayName(for: summary)).lineLimit(1)
                if hovering {
                    HStack(spacing: 10) {
                        if let tab { Button("Close") { tabs.close(tab) } }
                        Button(sessions.isArchived(summary.id) ? "Unarchive" : "Archive") {
                            if sessions.isArchived(summary.id) { sessions.unarchive(summary.id) } else { SessionActions.archive(summary, sessions: sessions, tabs: tabs) }
                        }
                        Button(sessions.isFavorite(summary.id) ? "Unstar" : "Star") { sessions.toggleFavorite(summary.id) }
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                } else {
                    Text(summary.activityDate, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            PRMarkView(refs: summary.pullRequests)
            if sessions.state.mutedSessions.contains(summary.id) { Image(systemName: "bell.slash").font(.caption).foregroundStyle(.tertiary) }
            if sessions.isFavorite(summary.id) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
        }
        .padding(.vertical, 2)
        .opacity(sessions.isArchived(summary.id) ? 0.5 : 1)
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
