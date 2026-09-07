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
                    .onTapGesture { tabs.reveal(sessionId: e.sessionId); dismiss() }
                    .contextMenu {
                        Button(sessions.state.mutedSessions.contains(e.sessionId) ? "Unmute Session" : "Mute Session") { toggleMute(e.sessionId) }
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

    private func icon(for kind: NotificationStore.Entry.Kind) -> String {
        switch kind { case .finished: "checkmark.circle"; case .needsPermission: "hand.raised"; case .needsInput: "questionmark.circle"; case .error: "exclamationmark.triangle" }
    }
    private func color(for kind: NotificationStore.Entry.Kind) -> Color {
        switch kind { case .finished: .green; case .needsPermission, .needsInput: .orange; case .error: .red }
    }
}
