import SwiftUI
import ClinicCore

struct SidebarView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Binding var showNewSession: Bool

    var body: some View {
        List(selection: Binding(get: { tabs.selectedTabId }, set: { if let id = $0 { tabs.selectedTabId = id } })) {
            let shells = tabs.tabs.filter { $0.kind == .shell }
            if !shells.isEmpty {
                Section("Shells") {
                    ForEach(shells) { tab in
                        Label(tab.title, systemImage: "terminal").tag(tab.id)
                            .contextMenu { Button("Close") { tabs.close(tab) } }
                    }
                }
            }
            ForEach(sessions.projects) { project in
                Section {
                    ForEach(sessions.sessions(in: project)) { summary in
                        SessionRow(summary: summary, tab: tabs.tab(for: summary.id))
                            .tag(tabs.tab(for: summary.id)?.id ?? UUID())
                            .contentShape(Rectangle())
                            .onTapGesture { tabs.open(session: summary) }
                            .contextMenu {
                                Button("Open") { tabs.open(session: summary) }
                                if let tab = tabs.tab(for: summary.id) { Button("Close Tab") { tabs.close(tab) } }
                                Divider()
                                Button("Copy Session ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary.id.rawValue, forType: .string) }
                                Button("Reveal Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.transcriptPath)]) }
                            }
                    }
                } header: {
                    HStack {
                        Text(project.name).help(project.path)
                        Spacer()
                        Text("\(sessions.sessions(in: project).count)").foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if sessions.projects.isEmpty && !sessions.isScanning {
                ContentUnavailableView("No sessions yet", systemImage: "tray", description: Text("Start one with ⌘N."))
            }
        }
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
        }
        .padding(.vertical, 2)
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
