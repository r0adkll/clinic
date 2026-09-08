import SwiftUI
import ClinicCore

/// Toolbar bell with unread badge and a history popover.
struct NotificationBell: View {
    @Environment(NotificationStore.self) private var store
    @State private var showPanel = false

    var body: some View {
        Button { showPanel.toggle(); store.markAllRead() } label: {
            Label("Notifications", systemImage: store.unreadCount > 0 ? "bell.badge" : "bell")
                .symbolRenderingMode(.palette)
                .foregroundStyle(store.unreadCount > 0 ? Color.accentColor : Color.primary, Color.primary)
        }
        .help(store.unreadCount > 0 ? "\(store.unreadCount) unread" : "Notification history")
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .popover(isPresented: $showPanel, arrowEdge: .bottom) { NotificationPanel() }
    }
}

struct NotificationPanel: View {
    @Environment(NotificationStore.self) private var store
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications").font(.headline)
                Spacer()
                Button("Clear") { store.clear() }.disabled(store.entries.isEmpty)
            }
            .padding(12)
            Divider()
            if store.entries.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "bell.slash", description: Text("Finished runs and sessions that need you show up here."))
                    .frame(height: 200)
            } else {
                List(store.entries) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(for: e.kind)).foregroundStyle(color(for: e.kind)).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).lineLimit(1)
                            Text(e.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(e.date, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { open(e); dismiss() }
                    .contextMenu {
                        Button("Mark Read") { store.markRead(e.id) }
                        Button("Remove") { store.remove(e.id) }
                        if let sid = e.sessionId {
                            Divider()
                            Button(sessions.state.mutedSessions.contains(sid) ? "Unmute Session" : "Mute Session") { toggleMute(sid) }
                        }
                    }
                }
                .listStyle(.plain)
                .frame(height: 320)
            }
        }
        .frame(width: 360)
    }

    private func toggleMute(_ id: SessionID) {
        sessions.update { s in if s.mutedSessions.contains(id) { s.mutedSessions.remove(id) } else { s.mutedSessions.insert(id) } }
    }

    private func open(_ e: NotificationStore.Entry) {
        store.markRead(e.id)
        if let url = e.url { NSWorkspace.shared.open(url) }
        else if let sid = e.sessionId { tabs.reveal(sessionId: sid) }
    }

    private func icon(for kind: NotificationStore.Entry.Kind) -> String {
        switch kind { case .finished: "checkmark.circle"; case .needsPermission: "hand.raised"; case .needsInput: "questionmark.circle"; case .error: "exclamationmark.triangle"; case .bell: "bell"; case .update: "arrow.down.circle" }
    }
    private func color(for kind: NotificationStore.Entry.Kind) -> Color {
        switch kind { case .finished: .green; case .needsPermission, .needsInput: .orange; case .error: .red; case .bell: .secondary; case .update: .blue }
    }
}


/// Slide-in card over the window when a session elsewhere wants attention (ADR-066).
struct NotificationCard: View {
    @Environment(NotificationStore.self) private var store
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions

    var body: some View {
        if let e = store.card {
            HStack(alignment: .top, spacing: 10) {
                if let sid = e.sessionId, let s = sessions.sessions[sid], let p = ProjectGrouping.project(for: s) {
                    ProjectIcon(project: p, size: 24)
                } else {
                    Image(systemName: e.kind == .update ? "arrow.down.circle" : "bell").font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(e.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button { store.dismissCard() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 10, y: 4)
            .contentShape(Rectangle())
            .onTapGesture {
                store.markRead(e.id); store.dismissCard()
                if let url = e.url { NSWorkspace.shared.open(url) } else if let sid = e.sessionId { tabs.reveal(sessionId: sid) }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(12)
        }
    }
}
