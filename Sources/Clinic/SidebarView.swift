import SwiftUI
import ClinicCore

struct SidebarView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Binding var showNewSession: Bool
    @State private var query = ""

    var body: some View {
        List(selection: selection) {
            let shells = tabs.tabs.filter { $0.kind == .shell }
            if !shells.isEmpty && query.isEmpty {
                Section("Shells") {
                    ForEach(shells) { tab in
                        Label(tab.title, systemImage: "terminal").tag(SidebarItem.tab(tab.id))
                            .contextMenu { Button("Close") { tabs.close(tab) } }
                    }
                }
            }
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
                        HStack {
                            Text(project.name).help(project.path)
                            Spacer()
                            Text("\(rows.count)").foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Filter sessions")
        .overlay {
            if sessions.projects.isEmpty && !sessions.isScanning {
                ContentUnavailableView("No sessions yet", systemImage: "tray", description: Text("Start one with ⌘N."))
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
    let summary: SessionSummary

    var body: some View {
        Button("Open") { tabs.open(session: summary) }
        if let tab = tabs.tab(for: summary.id) { Button("Close Tab") { tabs.close(tab) } }
        Divider()
        Button("Rename…") { SessionActions.rename(summary, sessions: sessions) }
        if sessions.state.manualNames[summary.id] != nil { Button("Clear Custom Name") { sessions.rename(summary.id, to: nil) } }
        Button(sessions.isFavorite(summary.id) ? "Remove from Favorites" : "Add to Favorites") { sessions.toggleFavorite(summary.id) }
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
    let summary: SessionSummary
    let tab: Tab?

    var body: some View {
        HStack(spacing: 8) {
            StateGlyph(tab: tab)
            VStack(alignment: .leading, spacing: 2) {
                Text(sessions.displayName(for: summary)).lineLimit(1)
                Text(summary.activityDate, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if sessions.isFavorite(summary.id) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
        }
        .padding(.vertical, 2)
        .opacity(sessions.isArchived(summary.id) ? 0.5 : 1)
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
        .frame(width: 8, height: 8)
    }
}
