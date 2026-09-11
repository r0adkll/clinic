import SwiftUI
import ClinicCore

/// What one window's Tasks screen shows (ADR-112): its view, filters and project, and its selection.
/// Every window has its own; a new one starts from the last filters used anywhere.
@MainActor
@Observable
final class TasksViewState {
    static let defaultsKey = "ClinicTasksFilters"

    var filter: WorkItemFilter { didSet { if filter != oldValue { save() } } }
    /// Narrows the view to one project's sources; nil = every project.
    var projectPath: String?
    var selectedID: String?

    init() {
        filter = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(WorkItemFilter.self, from: $0) } ?? WorkItemFilter()
    }

    /// Show Task (ADR-114): widen everything so the item is sure to be listed, then select it.
    func reveal(_ ref: WorkItemRef) {
        filter.view = .all
        filter.state = .all
        filter.clearRefinements()
        projectPath = nil
        selectedID = ref.id
    }

    private func save() {
        if let data = try? JSONEncoder().encode(filter) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

/// The actions a task offers from the list, the detail pane and the keyboard (ADR-112, ADR-114).
@MainActor
enum TaskActions {
    /// ↩ opens the composer pre-filled; ⌘↩ starts the session straight away.
    static func startSession(_ item: WorkItem, immediately: Bool, preferring project: String?,
                             store: TasksStore, tabs: TabStore, sessions: SessionStore) {
        guard let path = store.projectPath(for: item.ref, preferring: project) else { return }
        let prompt = store.provider.sessionPrompt(for: item)
        let branch = WorkItemBranch.name(for: item)
        if immediately {
            tabs.newSession(projectPath: path, model: sessions.state.lastModelByProject[path], worktree: true,
                            worktreeName: branch, prompt: prompt, workItem: item.ref)
        } else {
            tabs.startNewSession(projectPath: path, prompt: prompt, worktreeName: branch, workItem: item.ref)
        }
    }

    static func open(_ item: WorkItem) { NSWorkspace.shared.open(item.ref.url) }

    static func copyLink(_ item: WorkItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.ref.url.absoluteString, forType: .string)
    }
}

/// The Tasks screen (ADR-112): scope column | list | detail, under a header of filters.
struct TasksScreen: View {
    @Environment(TasksStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @FocusState private var searchFocused: Bool
    @State private var sourceSheet: TaskSourceTarget?

    private var state: TasksViewState { window.tasks }

    var body: some View {
        let all = store.items(includingClosed: state.filter.state.includesClosed)
        let scoped = scopedToProject(all)
        let visible = state.filter.apply(scoped, context: store.context)
        VStack(spacing: 0) {
            header(all: all)
            Divider()
            content(all: all, visible: visible)
            Divider()
            TasksFooter()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background { shortcuts(visible: visible) }
        .onAppear { store.appeared() }
        .onDisappear { store.disappeared() }
        .onChange(of: store.projects.map(\.path)) { store.projectsChanged() }
        .task(id: state.filter.state) { if state.filter.state.includesClosed { store.ensureClosed() } }
        .onChange(of: state.selectedID) { _, id in
            if let id, let item = store.item(id: id) { store.markViewed(item) }
        }
        .sheet(item: $sourceSheet) { TaskSourceSheet(projectPath: $0.path) }
    }

    private func scopedToProject(_ items: [WorkItem]) -> [WorkItem] {
        guard let path = state.projectPath else { return items }
        let ids = Set(store.sources(for: path).map(\.id))
        return items.filter { ids.contains($0.ref.source.id) }
    }

    private var selectedItem: WorkItem? { state.selectedID.flatMap(store.item(id:)) }

    // MARK: Header

    private func header(all: [WorkItem]) -> some View {
        @Bindable var state = state
        let facets = WorkItemFacets(all)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.clipboard").font(.title3).foregroundStyle(Color.accentColor)
                Text("Tasks").font(.title3.weight(.semibold))
                Text("Issues from your projects").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button { Task { await store.refreshAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.isRefreshing)
                    .help("Fetch every project's issues again (⌘R)")
            }
            HStack(spacing: 8) {
                searchField
                    .frame(maxWidth: 300)
                Picker("", selection: $state.filter.state) {
                    ForEach(WorkItemFilter.StateFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Closed issues are fetched on demand: the \(TasksStore.closedLimit) most recently updated per repository")
                labelsMenu(facets.labels)
                personMenu("Assignee", values: facets.assignees, selection: $state.filter.assignee, allowsUnassigned: true)
                personMenu("Author", values: facets.authors, selection: $state.filter.author)
                personMenu("Milestone", values: facets.milestones, selection: $state.filter.milestone)
                Menu {
                    Picker("Sort By", selection: $state.filter.sort) {
                        ForEach(WorkItemFilter.Sort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Group By", selection: $state.filter.grouping) {
                        ForEach(WorkItemFilter.Grouping.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(state.filter.sort.title, systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.button).fixedSize()
                if state.filter.hasRefinements {
                    Button("Clear") { state.filter.clearRefinements() }
                        .help("Clear the search and every filter")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    /// `SearchField`'s look, with a focus binding so ⌘F can reach it.
    private var searchField: some View {
        @Bindable var state = state
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Search tasks", text: $state.filter.text).textFieldStyle(.plain).focused($searchFocused)
            if !state.filter.text.isEmpty {
                Button { state.filter.text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .help("Title, body, repository or #number (⌘F)")
    }

    private func labelsMenu(_ labels: [WorkItemLabel]) -> some View {
        @Bindable var state = state
        let chosen = state.filter.labels
        return Menu {
            if labels.isEmpty { Text("No labels") }
            ForEach(labels, id: \.name) { label in
                Toggle(label.name, isOn: Binding(
                    get: { chosen.contains { $0.caseInsensitiveCompare(label.name) == .orderedSame } },
                    set: { on in
                        state.filter.labels = state.filter.labels.filter { $0.caseInsensitiveCompare(label.name) != .orderedSame }
                        if on { state.filter.labels.insert(label.name) }
                    }))
            }
            if !chosen.isEmpty { Divider(); Button("Any Label") { state.filter.labels = [] } }
        } label: {
            Text(chosen.isEmpty ? "Labels" : chosen.count == 1 ? chosen.first! : "\(chosen.count) Labels")
        }
        .menuStyle(.button).fixedSize()
        .help("Show only tasks carrying every chosen label")
    }

    private func personMenu(_ title: String, values: [String], selection: Binding<String?>, allowsUnassigned: Bool = false) -> some View {
        Menu {
            Button("Any \(title)") { selection.wrappedValue = nil }
            if allowsUnassigned { Button("Unassigned") { selection.wrappedValue = WorkItemFilter.unassigned } }
            if !values.isEmpty { Divider() }
            ForEach(values, id: \.self) { v in
                Button { selection.wrappedValue = v } label: {
                    if selection.wrappedValue == v { Label(v, systemImage: "checkmark") } else { Text(v) }
                }
            }
        } label: {
            switch selection.wrappedValue {
            case nil: Text(title)
            case .some(WorkItemFilter.unassigned): Text("Unassigned")
            case let v?: Text(v)
            }
        }
        .menuStyle(.button).fixedSize()
    }

    // MARK: Content

    @ViewBuilder
    private func content(all: [WorkItem], visible: [WorkItem]) -> some View {
        if let availability = store.availability, !availability.isReady {
            GitHubUnavailableView(availability: availability, subject: "issues") { await store.retry() }
        } else {
            GeometryReader { geo in
                let listWidth = min(460, max(300, (geo.size.width - TasksScopeColumn.width) * 0.42))
                HStack(spacing: 0) {
                    TasksScopeColumn(all: all, onEditSource: { sourceSheet = TaskSourceTarget(path: $0) })
                        .frame(width: TasksScopeColumn.width)
                    Divider()
                    TaskList(items: visible, anyItems: !all.isEmpty, onStart: start)
                        .frame(width: listWidth)
                    Divider()
                    Group {
                        if let item = selectedItem {
                            TaskDetailView(item: item, onStart: { start(item, immediately: $0) })
                        } else {
                            ContentUnavailableView("Nothing selected", systemImage: "list.bullet.clipboard",
                                                   description: Text("Pick a task to read it, or press ↩ on one to start a session for it."))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func start(_ item: WorkItem, immediately: Bool) {
        TaskActions.startSession(item, immediately: immediately, preferring: state.projectPath,
                                 store: store, tabs: tabs, sessions: sessions)
    }

    /// The screen's own keys (ADR-112). Zero-size buttons, so they exist only while the screen does.
    private func shortcuts(visible: [WorkItem]) -> some View {
        ZStack {
            Button("") { searchFocused = true }.keyboardShortcut("f")
            Button("") { Task { await store.refreshAll() } }.keyboardShortcut("r")
            Button("") { if let i = selectedItem { TaskActions.open(i) } }.keyboardShortcut("o")
            Button("") { if let i = selectedItem { TaskActions.copyLink(i) } }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("") { if let i = selectedItem { start(i, immediately: true) } }.keyboardShortcut(.return, modifiers: .command)
            ForEach(Array(WorkItemFilter.View.allCases.enumerated()), id: \.element) { i, v in
                Button("") { state.filter.view = v }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .control)
            }
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
}

struct TaskSourceTarget: Identifiable { let path: String; var id: String { path } }

/// The window's answers to ⌥⌘T, Show Task and Task Source… (ADR-112, ADR-113, ADR-114).
struct TasksRouting: ViewModifier {
    let window: WindowState
    let isActive: Bool
    @State private var taskSourceProject: TaskSourceTarget?

    func body(content: Content) -> some View {
        content
            .sheet(item: $taskSourceProject) { TaskSourceSheet(projectPath: $0.path) }
            .onReceive(NotificationCenter.default.publisher(for: .clinicTasks)) { _ in if isActive { window.screen = .tasks } }
            .onReceive(NotificationCenter.default.publisher(for: .clinicShowTask)) { n in
                guard isActive, let ref = n.object as? WorkItemRef else { return }
                window.tasks.reveal(ref)
                window.screen = .tasks
            }
            .onReceive(NotificationCenter.default.publisher(for: .clinicTaskSource)) { n in
                guard isActive, let path = n.object as? String else { return }
                taskSourceProject = TaskSourceTarget(path: path)
            }
    }
}

// MARK: - Scope column

/// Views, then projects; one of each selected at a time, independently (ADR-112).
struct TasksScopeColumn: View {
    static let width: CGFloat = 220
    @Environment(TasksStore.self) private var store
    @Environment(WindowState.self) private var window
    let all: [WorkItem]
    let onEditSource: (String) -> Void

    var body: some View {
        let state = window.tasks
        let ctx = store.context
        let viewCounts = state.filter.viewCounts(all, context: ctx)
        let sourceCounts = state.filter.sourceCounts(all, context: ctx)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                caption("Views")
                ForEach(Array(WorkItemFilter.View.allCases.enumerated()), id: \.element) { i, view in
                    ScopeRow(selected: state.filter.view == view, count: viewCounts[view] ?? 0,
                             help: "\(view.title) (⌃\(i + 1))") {
                        Image(systemName: Self.symbol(view)).font(.system(size: 12, weight: .medium)).frame(width: 18)
                        Text(view.title)
                    } action: { state.filter.view = view }
                }
                caption("Projects").padding(.top, 10)
                ScopeRow(selected: state.projectPath == nil, count: sourceCounts.values.reduce(0, +), help: "Every project") {
                    Image(systemName: "square.stack").font(.system(size: 12, weight: .medium)).frame(width: 18)
                    Text("All Projects")
                } action: { state.projectPath = nil }
                ForEach(store.projects) { project in
                    projectRow(project, counts: sourceCounts)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func projectRow(_ project: Project, counts: [String: Int]) -> some View {
        let state = window.tasks
        let resolution = store.resolution(for: project.path)
        let sources = resolution?.sources ?? []
        let error = sources.compactMap { store.sourceErrors[$0.id] }.first
        let loading = sources.contains { store.loadingSources.contains($0.id) }
        let count = sources.reduce(0) { $0 + (counts[$1.id] ?? 0) }
        let unresolved = resolution?.reason
        ScopeRow(selected: state.projectPath == project.path, count: sources.isEmpty ? nil : count,
                 dimmed: sources.isEmpty, help: help(project, resolution: resolution, error: error)) {
            ProjectIcon(project: project, size: 18).opacity(sources.isEmpty ? 0.5 : 1)
            Text(project.name)
            if loading { ProgressView().controlSize(.mini) }
            if error != nil { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange) }
        } action: {
            state.projectPath = state.projectPath == project.path ? nil : project.path
        }
        .contextMenu {
            Button("Task Source…") { onEditSource(project.path) }
            if let url = sources.first?.webURL { Button("Open Issues on GitHub") { NSWorkspace.shared.open(url.appendingPathComponent("issues")) } }
            if unresolved == nil && sources.isEmpty { Text("Resolving…") }
        }
    }

    private func help(_ project: Project, resolution: WorkItemSourceResolution?, error: String?) -> String {
        var lines = [project.path]
        switch resolution {
        case .resolved(let sources)?: lines.append(sources.map(\.scope).joined(separator: ", ") + (store.isOverridden(project.path) ? " (set by hand)" : ""))
        case .unresolved(let reason)?: lines.append(reason)
        case nil: lines.append("Not resolved yet")
        }
        if let error { lines.append("Last fetch failed: \(error)") }
        return lines.joined(separator: "\n")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.leading, 8).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    static func symbol(_ view: WorkItemFilter.View) -> String {
        switch view {
        case .assigned: "person.crop.circle"
        case .created: "square.and.pencil"
        case .mentioned: "at"
        case .all: "tray.full"
        }
    }
}

/// A source-list row: an accent pill when selected, the sidebar's hover fill otherwise (ADR-110).
private struct ScopeRow<Content: View>: View {
    let selected: Bool
    let count: Int?
    let dimmed: Bool
    let help: String
    let label: Content
    let action: () -> Void
    @State private var hovering = false

    init(selected: Bool, count: Int?, dimmed: Bool = false, help: String,
         @ViewBuilder label: () -> Content, action: @escaping () -> Void) {
        self.selected = selected; self.count = count; self.dimmed = dimmed; self.help = help
        self.label = label(); self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                label.lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)").font(.caption).monospacedDigit()
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(selected ? AnyShapeStyle(Color.accentColor) : hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - List

struct TaskList: View {
    @Environment(TasksStore.self) private var store
    @Environment(WindowState.self) private var window
    let items: [WorkItem]
    /// Something is cached at all, as opposed to this filter matching nothing.
    let anyItems: Bool
    let onStart: (WorkItem, Bool) -> Void

    var body: some View {
        @Bindable var state = window.tasks
        List(selection: $state.selectedID) {
            if state.filter.grouping == .project {
                ForEach(groups, id: \.path) { group in
                    Section {
                        ForEach(group.items) { row($0) }
                    } header: {
                        HStack(spacing: 6) {
                            ProjectIcon(project: Project(path: group.path), size: 14)
                            Text(Project(path: group.path).name).font(.subheadline.weight(.semibold))
                            Text("\(group.items.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ForEach(items) { row($0) }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.return) {
            guard let id = state.selectedID, let item = items.first(where: { $0.id == id }) else { return .ignored }
            onStart(item, false)
            return .handled
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) {
                Button("Start Session…") { onStart(item, false) }
                Button("Start Session Now") { onStart(item, true) }
                Divider()
                Button("Open on GitHub") { TaskActions.open(item) }
                Button("Copy Link") { TaskActions.copyLink(item) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) { onStart(item, false) }
        }
        .overlay { emptyState }
    }

    private func row(_ item: WorkItem) -> some View {
        TaskRow(item: item, projectPath: store.projectPath(for: item.ref, preferring: window.tasks.projectPath),
                updated: store.isUpdatedSinceViewed(item), sessions: store.linkedSessionCount(item.ref))
            .tag(item.id)
    }

    private struct ProjectGroup { let path: String; var items: [WorkItem] }

    /// Items under the project that runs their sessions, in roster order.
    private var groups: [ProjectGroup] {
        var byPath: [String: [WorkItem]] = [:]
        for item in items {
            byPath[store.projectPath(for: item.ref) ?? item.ref.source.scope, default: []].append(item)
        }
        let order = store.projects.map(\.path)
        return byPath.map { ProjectGroup(path: $0.key, items: $0.value) }
            .sorted { (order.firstIndex(of: $0.path) ?? .max) < (order.firstIndex(of: $1.path) ?? .max) }
    }

    @ViewBuilder
    private var emptyState: some View {
        let state = window.tasks
        if items.isEmpty {
            if !anyItems && (store.isRefreshing || store.availability == nil) {
                ProgressView("Loading issues…")
            } else if store.allSources.isEmpty && !store.isRefreshing {
                ContentUnavailableView("No task sources", systemImage: "link",
                                       description: Text("None of your projects points at a GitHub repository gh knows. Right-click a project to set its task source."))
            } else if state.filter.hasRefinements {
                ContentUnavailableView {
                    Label("No matching tasks", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing in \(state.filter.view.title) matches the search and filters.")
                } actions: {
                    Button("Clear Filters") { window.tasks.filter.clearRefinements() }
                }
            } else if state.filter.view != .all {
                ContentUnavailableView {
                    Label(emptyTitle(state.filter.view), systemImage: TasksScopeColumn.symbol(state.filter.view))
                } description: {
                    Text(state.projectPath.map { "Nothing here in \(Project(path: $0).name)." } ?? "Nothing here across your projects.")
                } actions: {
                    Button("Show All") { window.tasks.filter.view = .all }
                }
            } else {
                ContentUnavailableView("No open issues", systemImage: "checkmark.circle",
                                       description: Text("Every issue here is closed."))
            }
        }
    }

    private func emptyTitle(_ view: WorkItemFilter.View) -> String {
        switch view {
        case .assigned: "Nothing assigned to you"
        case .created: "Nothing you opened"
        case .mentioned: "No mentions"
        case .all: "No issues"
        }
    }
}

/// One task in the list (ADR-112).
struct TaskRow: View {
    let item: WorkItem
    let projectPath: String?
    let updated: Bool
    let sessions: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TaskStateGlyph(item: item).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title).font(.body.weight(.semibold)).lineLimit(2)
                    if updated {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                            .help("Updated since you last opened it")
                    }
                    Spacer(minLength: 0)
                    if sessions > 0 {
                        Label("\(sessions)", systemImage: "terminal")
                            .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                            .help("\(sessions) session\(sessions == 1 ? "" : "s") started from this task")
                    }
                }
                HStack(spacing: 5) {
                    if let projectPath { ProjectIcon(project: Project(path: projectPath), size: 13) }
                    Text(item.ref.shortDisplay).monospacedDigit()
                    Text("·")
                    Text(item.author).lineLimit(1)
                    Text("·")
                    Text(TaskRow.age(item.updatedAt)).help("Updated \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    Spacer(minLength: 0)
                    if item.commentCount > 0 {
                        Label("\(item.commentCount)", systemImage: "bubble.left").labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !item.labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.labels.prefix(3), id: \.name) { LabelCapsule(label: $0) }
                        if item.labels.count > 3 {
                            Text("+\(item.labels.count - 3)").font(.caption2).foregroundStyle(.secondary)
                                .help(item.labels.dropFirst(3).map(\.name).joined(separator: ", "))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// "now", "5m", "3h", "2d", "3w", then a date.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        case ..<(86_400 * 14): return "\(Int(s / 86_400))d"
        case ..<(86_400 * 60): return "\(Int(s / (86_400 * 7)))w"
        default: return date.formatted(.dateTime.month(.abbreviated).day().year(Calendar.current.isDate(date, equalTo: now, toGranularity: .year) ? .omitted : .defaultDigits))
        }
    }
}

/// GitHub's own state colours: they are information, like PR status (ADR-112).
struct TaskStateGlyph: View {
    let item: WorkItem
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(color)
            .help(help)
    }

    private var notPlanned: Bool { item.stateReason == "not_planned" }
    private var symbol: String {
        item.state == .open ? "smallcircle.filled.circle" : notPlanned ? "slash.circle" : "checkmark.circle"
    }
    private var color: Color { item.state == .open ? .green : notPlanned ? .secondary : .purple }
    private var help: String { item.state == .open ? "Open" : notPlanned ? "Closed as not planned" : "Closed as completed" }
}

/// A GitHub label in its own colour (ADR-112): a wash of it behind a hairline of it, with the text
/// pushed toward whichever end of the colour reads on this appearance.
struct LabelCapsule: View {
    let label: WorkItemLabel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let base = LabelCapsule.color(hex: label.color) ?? Color.secondary
        Text(label.name)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(LabelCapsule.textColor(hex: label.color, dark: scheme == .dark) ?? Color.secondary)
            .background(base.opacity(scheme == .dark ? 0.22 : 0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(base.opacity(scheme == .dark ? 0.55 : 0.45), lineWidth: 0.5))
    }

    static func rgb(hex: String?) -> (Double, Double, Double)? {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    static func color(hex: String?) -> Color? {
        rgb(hex: hex).map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    }

    /// Keeps the hue; lifts brightness on dark, lowers it on light, so pale yellows and deep navies
    /// both read. Greys stay grey.
    static func textColor(hex: String?, dark: Bool) -> Color? {
        guard let (r, g, b) = rgb(hex: hex) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        if dark {
            return Color(hue: Double(h), saturation: min(Double(s), 0.55), brightness: max(Double(v), 0.9))
        }
        return Color(hue: Double(h), saturation: s < 0.08 ? Double(s) : max(Double(s), 0.6), brightness: min(Double(v), 0.5))
    }
}

// MARK: - Footer

struct TasksFooter: View {
    @Environment(TasksStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                Text(summary(now: context.date))
                if let first = store.truncatedSources.first {
                    Text("·")
                    Label("Showing the \(TasksStore.openLimit) most recently updated in \(first.scope)", systemImage: "exclamationmark.circle")
                        .help(store.truncatedSources.map(\.scope).joined(separator: ", "))
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.bar)
        }
    }

    private func summary(now: Date) -> String {
        var parts: [String] = []
        if let last = store.lastRefresh {
            parts.append("Updated " + (now.timeIntervalSince(last) < 60 ? "just now" : TaskRow.age(last, now: now) + " ago"))
        } else if store.isRefreshing {
            parts.append("Updating…")
        }
        let n = store.allSources.count
        parts.append("\(n) source\(n == 1 ? "" : "s")")
        parts.append("\(store.openCount) open")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Task source sheet (ADR-113)

/// Automatic (whatever `gh` resolves in the folder), a repository typed by hand, or None.
struct TaskSourceSheet: View {
    @Environment(TasksStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectPath: String

    private enum Mode: Hashable { case automatic, repository, none }
    @State private var mode: Mode = .automatic
    @State private var repository = ""
    @State private var host = "github.com"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProjectIcon(project: Project(path: projectPath), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Task Source").font(.headline)
                    Text(Project(path: projectPath).name).font(.callout).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $mode) {
                Text("Automatic").tag(Mode.automatic)
                Text("GitHub repository").tag(Mode.repository)
                Text("None").tag(Mode.none)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            Group {
                switch mode {
                case .automatic:
                    Text(automaticDescription).foregroundStyle(.secondary)
                case .repository:
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text("Repository").foregroundStyle(.secondary)
                            TextField("owner/repo", text: $repository).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Host").foregroundStyle(.secondary)
                            TextField("github.com", text: $host).textFieldStyle(.roundedBorder)
                        }
                    }
                case .none:
                    Text("This project's issues stay out of Tasks.").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == .repository && !isValidRepository)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: load)
    }

    private var automaticDescription: String {
        if case .resolved(let s)? = store.resolutions[projectPath] {
            return "Uses \(s.map(\.scope).joined(separator: ", ")), the repository gh picks in this folder: its default if you set one, else upstream, then origin."
        }
        if let reason = store.resolutions[projectPath]?.reason { return "gh picks the repository in this folder. Right now: \(reason)." }
        return "gh picks the repository in this folder: its default if you set one, else upstream, then origin."
    }

    private var trimmedRepository: String { repository.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private var isValidRepository: Bool {
        let parts = trimmedRepository.split(separator: "/")
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }

    private func load() {
        switch store.resolution(for: projectPath) {
        case .resolved(let s)? where store.isOverridden(projectPath):
            mode = .repository; repository = s.first?.scope ?? ""; host = s.first?.host ?? "github.com"
        case .unresolved? where store.isOverridden(projectPath):
            mode = .none
        default:
            mode = .automatic
            if let s = store.resolutions[projectPath]?.sources.first { repository = s.scope; host = s.host }
        }
    }

    private func save() {
        switch mode {
        case .automatic: store.setSourceOverride(nil, for: projectPath)
        case .none: store.setSourceOverride([], for: projectPath)
        case .repository:
            let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
            store.setSourceOverride([.github(trimmedRepository, host: h.isEmpty ? "github.com" : h)], for: projectPath)
        }
    }
}
