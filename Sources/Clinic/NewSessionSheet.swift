import SwiftUI
import ClinicCore

/// "Where should this session run?" — asked only when no project is in view: the home screen, ⇧⌘N,
/// the status item (ADR-121). It is a picker and nothing else. Model, effort and worktree belong to the
/// composer that opens next ([[ADR-082]]), so asking for them here asked twice.
///
/// Type to filter, arrows to move, Return to continue: `QuickSwitcher`'s keyboard. One click on a row
/// continues too. A folder dropped anywhere on the sheet becomes a project and continues with it.
struct NewSessionSheet: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(KeyBindings.self) private var bindings
    @Environment(\.dismiss) private var dismiss
    var initialProject: String? = nil

    @State private var query = ""
    @State private var highlighted: String?
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    private enum Metrics {
        static let width: CGFloat = 540
        static let sheet: CGFloat = 20
        static let section: CGFloat = 14
        static let row: CGFloat = 46
        static let rowGap: CGFloat = 2
        static let listHeight: CGFloat = 5.5 * (row + rowGap)
        static let corner: CGFloat = 10
    }

    var body: some View {
        let rows = self.rows
        VStack(alignment: .leading, spacing: Metrics.section) {
            header
            searchField(rows: rows)
            list(rows: rows)
            Divider()
            footer(rows: rows)
        }
        .padding(Metrics.sheet)
        .frame(width: Metrics.width)
        .overlay { if dropTargeted { dropOverlay } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) else { return false }
            startInFolder(folder.path)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear {
            searchFocused = true
            highlighted = initialHighlight(in: rows)
        }
        .onChange(of: query) { highlighted = firstMatch(in: self.rows) }
    }

    // MARK: Rows

    private enum Row: Identifiable {
        case chat(path: String)
        case project(Project, lastActive: Date?, count: Int)

        var id: String {
            switch self {
            case .chat(let path): path
            case .project(let p, _, _): p.path
            }
        }
    }

    /// Chat first, as in the automation target list (ADR-095), then projects by their latest visible
    /// session: the project you were last in is the one you most likely want. Projects with nothing in
    /// them yet follow in sidebar order. A filter ranks by where it matched before recency, so "ca"
    /// puts Campfire above a project that only has "Appli*ca*tion" somewhere in its path.
    private var rows: [Row] {
        var latest: [String: Date] = [:], counts: [String: Int] = [:]
        for s in sessions.sessions.values where sessions.isVisible(s) && !sessions.isArchived(s.id) {
            guard let path = ProjectGrouping.project(for: s)?.path else { continue }
            counts[path, default: 0] += 1
            if s.activityDate > latest[path] ?? .distantPast { latest[path] = s.activityDate }
        }
        let projects = sessions.projects.filter { !SessionStore.isChats($0.path) }
        let order = Dictionary(projects.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        let ranked = projects.compactMap { p in rank(p).map { (p, $0) } }
        let sorted = ranked.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            switch (latest[a.0.path], latest[b.0.path]) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return order[a.0.path, default: 0] < order[b.0.path, default: 0]
            }
        }
        var out: [Row] = rank(chat: ()) != nil ? [.chat(path: SessionStore.chatsDirectory)] : []
        for (p, _) in sorted {
            out.append(.project(p, lastActive: latest[p.path], count: counts[p.path] ?? 0))
        }
        return out
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// 0 = the name starts with the filter, 1 = the name contains it, 2 = only the path does; nil = no match.
    private func rank(_ project: Project) -> Int? {
        let q = trimmedQuery
        guard !q.isEmpty else { return 0 }
        if project.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 0 }
        if project.name.localizedCaseInsensitiveContains(q) { return 1 }
        return TabFooter.abbreviate(project.path).localizedCaseInsensitiveContains(q) ? 2 : nil
    }

    private func rank(chat: Void) -> Int? {
        let q = trimmedQuery
        return q.isEmpty || "chat".range(of: q, options: [.caseInsensitive, .anchored]) != nil ? 0 : nil
    }

    /// The project the request came from, else the most recent project. Never Chat: New Chat has its
    /// own command, so reaching this sheet means a repository was wanted.
    private func initialHighlight(in rows: [Row]) -> String? {
        if let initialProject, rows.contains(where: { $0.id == initialProject }) { return initialProject }
        return firstMatch(in: rows)
    }

    private func firstMatch(in rows: [Row]) -> String? {
        rows.first { if case .project = $0 { true } else { false } }?.id ?? rows.first?.id
    }

    private func move(_ delta: Int, in rows: [Row]) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : rows.count)
        highlighted = rows[min(max(current + delta, 0), rows.count - 1)].id
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            AccentTile(symbol: "square.and.pencil", size: 34, glyph: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("New Session").font(.title3.weight(.semibold))
                Text("Choose where it runs. You write the prompt next.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
    }

    // MARK: Search

    /// The composer card's field treatment: text background, hairline, accent ring while focused.
    private func searchField(rows: [Row]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter projects", text: $query)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("Clear")
            }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor),
                              lineWidth: searchFocused ? 1.5 : 1)
        }
        .animation(.easeOut(duration: 0.12), value: searchFocused)
    }

    // MARK: List

    private func list(rows: [Row]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.rowGap) {
                    ForEach(rows) { row in
                        if case .project = row, row.id == firstProjectId(in: rows), rows.first?.id == SessionStore.chatsDirectory {
                            Divider().padding(.horizontal, 8).padding(.vertical, 3)
                        }
                        rowView(row, in: rows).id(row.id)
                    }
                    if rows.isEmpty { emptyState }
                }
                .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: Metrics.listHeight)
            .onChange(of: highlighted) { if let id = highlighted { proxy.scrollTo(id) } }
        }
    }

    private func firstProjectId(in rows: [Row]) -> String? {
        rows.first { if case .project = $0 { true } else { false } }?.id
    }

    @ViewBuilder private func rowView(_ row: Row, in rows: [Row]) -> some View {
        let isHighlighted = row.id == highlighted
        switch row {
        case .chat:
            ProjectPickerRow(highlighted: isHighlighted,
                             title: "Chat",
                             detail: "No repository · runs in Clinic's scratch folder",
                             detailIsPath: false,
                             trailing: bindings.chord(for: .newChat).map { Text($0.display) }) {
                ProjectIcon(project: Project(path: SessionStore.chatsDirectory), size: 28)
            } action: { choose(row.id, in: rows) }
        case .project(let project, let lastActive, let count):
            ProjectPickerRow(highlighted: isHighlighted,
                             title: project.name,
                             detail: TabFooter.abbreviate(project.path),
                             detailIsPath: true,
                             trailing: Self.activity(lastActive, count: count)) {
                ProjectIcon(project: project, size: 28)
            } action: { choose(row.id, in: rows) }
        }
    }

    /// "3 sessions · 2 hr. ago", or "No sessions yet" for a project just added.
    private static func activity(_ date: Date?, count: Int) -> Text {
        guard let date, count > 0 else { return Text("No sessions yet") }
        return Text("\(count) \(count == 1 ? "session" : "sessions") · \(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder.badge.questionmark").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text("No project matches “\(trimmedQuery)”").font(.callout).foregroundStyle(.secondary)
            Button("Choose Folder…") { chooseFolder() }
                .buttonStyle(.link).font(.callout)
        }
        .frame(maxWidth: .infinity).padding(.top, 48)
    }

    // MARK: Footer

    private func footer(rows: [Row]) -> some View {
        HStack(spacing: 10) {
            Button { chooseFolder() } label: { Label("Choose Folder…", systemImage: "folder.badge.plus") }
                .controlSize(.large)
                .help("Start in a folder that isn't a project yet. Dropping one on this sheet works too.")
            Spacer(minLength: 8)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction).controlSize(.large)
            Button("Continue") { choose(highlighted, in: rows) }
                .keyboardShortcut(.defaultAction).controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(highlighted.map { id in !rows.contains { $0.id == id } } ?? true)
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.accentColor.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .overlay {
                VStack(spacing: 8) {
                    AccentTile(symbol: "folder.badge.plus", size: 44, glyph: 22)
                    Text("Drop to start a session in this folder").font(.headline)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(8)
            .allowsHitTesting(false)
    }

    // MARK: Actions

    private func choose(_ id: String?, in rows: [Row]) {
        guard let id, let row = rows.first(where: { $0.id == id }) else { return }
        dismiss()
        switch row {
        case .chat: tabs.newChat()
        case .project(let project, _, _): tabs.startNewSession(projectPath: project.path)
        }
    }

    private func chooseFolder() {
        guard let path = ProjectFolderPicker.choose() else { return }
        startInFolder(path)
    }

    private func startInFolder(_ path: String) {
        sessions.addProject(path)
        dismiss()
        tabs.startNewSession(projectPath: path)
    }
}

/// One destination. Its own view for hover: the keyboard highlight wears the accent wash, the pointer
/// a quieter fill, so the two never read as the same thing while an arrow key scrolls the list under it.
private struct ProjectPickerRow<Icon: View>: View {
    let highlighted: Bool
    let title: String
    let detail: String
    let detailIsPath: Bool
    let trailing: Text?
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(detail)
                        .font(detailIsPath ? .system(size: 11).monospaced() : .system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(detailIsPath ? .head : .tail)
                }
                Spacer(minLength: 8)
                if let trailing {
                    trailing.font(.system(size: 11)).foregroundStyle(highlighted ? .secondary : .tertiary).lineLimit(1)
                }
                if highlighted { KeyCap("↩") }
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: AnyShapeStyle {
        if highlighted { return AnyShapeStyle(Color.accentColor.opacity(0.14)) }
        return hovering ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(Color.clear)
    }
}
