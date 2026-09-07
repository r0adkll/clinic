import SwiftUI
import ClinicCore

/// ⌘K: type to filter, arrows to move, Return to open.
struct QuickSwitcher: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [SessionSummary] {
        sessions.sessions.values.filter { sessions.isVisible($0) && sessions.matches($0, query: query) }
            .sorted { ($0.activityDate, $0.id.rawValue) > ($1.activityDate, $1.id.rawValue) }
            .prefix(30).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Jump to session", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onSubmit { openHighlighted() }
                .onChange(of: query) { highlighted = 0 }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, s in
                        HStack {
                            StateGlyph(tab: tabs.tab(for: s.id))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sessions.displayName(for: s)).lineLimit(1)
                                Text(ProjectGrouping.project(for: s)?.name ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(s.activityDate, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(i == highlighted ? Color.accentColor.opacity(0.2) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { highlighted = i; openHighlighted() }
                        .id(s.id)
                    }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { if results.indices.contains(highlighted) { proxy.scrollTo(results[highlighted].id) } }
            }
        }
        .frame(width: 560, height: 400)
        .onAppear { focused = true }
    }

    private func openHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        tabs.open(session: results[highlighted])
        dismiss()
    }
}
