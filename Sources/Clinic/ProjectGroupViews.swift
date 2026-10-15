import SwiftUI
import ClinicCore

/// What a dragged group header carries. Project headers drag their bare path, so a group's id is
/// prefixed to tell the two apart in a shared `String` drop (ADR-210).
enum ProjectGroupDrag {
    private static let prefix = "clinic-group:"
    static func payload(_ id: UUID) -> String { prefix + id.uuidString }
    static func groupId(_ payload: String) -> UUID? {
        payload.hasPrefix(prefix) ? UUID(uuidString: String(payload.dropFirst(prefix.count))) : nil
    }
}

/// What a folded project or group, or a chip, says about the open sessions it hides (ADR-210). It counts
/// what the Dock badge counts: a session waiting on you (orange), and one that finished a turn you have
/// not looked at (blue). The finished-and-unread case is the common one; counting only waiting sessions
/// left a folded group blank exactly when a turn had ended for you.
struct HiddenAttention: Equatable {
    var waiting = 0
    var unread = 0

    var isEmpty: Bool { waiting + unread == 0 }
    /// Orange outranks blue, as on a session's own glyph.
    var color: Color { waiting > 0 ? .orange : .blue }
    /// "2 need you" while anything waits; otherwise "1 new".
    var summary: String {
        if waiting > 0 { let n = waiting + unread; return n == 1 ? "1 needs you" : "\(n) need you" }
        return "\(unread) new"
    }
    var spoken: String {
        if waiting > 0 { return "\(waiting) waiting on you" + (unread > 0 ? ", \(unread) unread" : "") }
        return "\(unread) unread"
    }
}

extension TabStore {
    /// Sessions in these projects that want the reader (ADR-210), each counted once, under the project
    /// its row is listed in. Waiting: an open tab at a prompt, an unanswered Grill round (open or not, as
    /// its card shows), or a detached agent asking. Unread: an open tab that finished unseen and is not
    /// working again, the way its glyph shows the arc rather than the blue dot.
    func attention(in paths: Set<String>) -> HiddenAttention {
        var a = HiddenAttention()
        var counted: Set<SessionID> = []
        func listed(_ id: SessionID) -> Bool { sessions.sidebarProjectPath(of: id).map(paths.contains) ?? false }
        for tab in tabs {
            guard let id = tab.sessionId, sessions.sidebarProjectPath(of: id).map(paths.contains) ?? paths.contains(tab.projectPath) else { continue }
            switch tab.state {
            case .waitingForInput, .waitingForPermission: a.waiting += 1; counted.insert(id)
            case .working, .launching: break
            default:
                if !sessions.openGrillRounds(for: id).isEmpty { a.waiting += 1; counted.insert(id) }
                else if tab.unread { a.unread += 1; counted.insert(id) }
            }
        }
        for id in sessions.state.grillRounds.keys where !counted.contains(id) && tab(for: id) == nil
            && !sessions.isArchived(id) && !sessions.openGrillRounds(for: id).isEmpty && listed(id) {
            a.waiting += 1; counted.insert(id)
        }
        for agent in backgroundAgents?.background ?? [] where agent.isRunning && agent.needsAttention {
            guard let id = agent.sessionId, !counted.contains(id), tab(for: id) == nil, listed(id) else { continue }
            a.waiting += 1; counted.insert(id)
        }
        return a
    }
}

extension WindowState {
    /// The scope, or nil when it names a group that has since been deleted.
    func activeGroupScope(in sessions: SessionStore) -> UUID? {
        guard let scope = groupScope, sessions.groups.contains(where: { $0.id == scope }) else { return nil }
        return scope
    }
}

@MainActor
enum GroupActions {
    /// Asks for a group's name. Nil when cancelled.
    static func promptName(title: String, initial: String = "", confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Groups are Clinic's own; nothing on disk changes."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        field.placeholderString = "Group name"
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func newGroup(sessions: SessionStore, with paths: [String] = []) {
        guard let name = promptName(title: "New Group", confirm: "Create") else { return }
        sessions.addGroup(named: name, with: paths)
    }

    static func rename(_ group: ProjectGroup, sessions: SessionStore) {
        guard let name = promptName(title: "Rename Group", initial: group.name, confirm: "Rename") else { return }
        sessions.renameGroup(group.id, to: name)
    }

    /// Steps a window's scope through All and then each group, wrapping (ADR-210).
    static func cycleScope(_ window: WindowState, sessions: SessionStore, by step: Int) {
        let stops: [UUID?] = [nil] + sessions.groups.map(\.id)
        guard stops.count > 1 else { return }
        let at = stops.firstIndex(of: window.activeGroupScope(in: sessions)) ?? 0
        window.groupScope = stops[(at + step + stops.count) % stops.count]
    }
}

/// A row of chips that scopes this window's sidebar to one group, or All (ADR-210). Shown only once a
/// group exists, and wrapped rather than scrolled, so every chip's needs-you dot stays in view.
struct GroupScopeChips: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs
    @Environment(WindowState.self) private var window

    var body: some View {
        let scope = window.activeGroupScope(in: sessions)
        FlowLayout(spacing: 6) {
            GroupChip(title: "All", selected: scope == nil, attention: HiddenAttention(), help: "Every project") {
                window.groupScope = nil
            }
            ForEach(sessions.groups) { group in
                // A chip's dot is for what you cannot see: the scoped group's sessions are already listed.
                GroupChip(title: group.name, selected: scope == group.id,
                          attention: scope == group.id ? HiddenAttention() : tabs.attention(in: group.members),
                          help: "Show only \(group.name)", group: group) {
                    window.groupScope = group.id
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The nav pills' and project rows' leading edge (ADR-209).
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}

private struct GroupChip: View {
    @Environment(SessionStore.self) private var sessions
    let title: String
    let selected: Bool
    let attention: HiddenAttention
    let help: String
    var group: ProjectGroup? = nil
    let action: () -> Void
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                if !attention.isEmpty { Circle().fill(attention.color).frame(width: 6, height: 6) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(fill, in: Capsule())
            .overlay { if dropTargeted { Capsule().strokeBorder(Color.accent, lineWidth: 2) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(attention.isEmpty ? title : "\(title), \(attention.spoken)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { if let group { GroupMenu(group: group) } }
        .dropDestination(for: String.self) { items, _ in
            guard let group, let path = items.first, ProjectGroupDrag.groupId(path) == nil, !SessionStore.isChats(path) else { return false }
            sessions.move(project: path, toGroup: group.id)
            return true
        } isTargeted: { dropTargeted = $0 && group != nil }
    }

    private var fill: AnyShapeStyle {
        if selected { return AnyShapeStyle(Color.accent) }
        return AnyShapeStyle(Color.primary.opacity(hovering ? 0.14 : 0.08))
    }
}

/// A group's caption in the All scope (ADR-210): Finder's sidebar section look, above ordinary project
/// headers. Clicking folds it; folded, it shows its members' tiles and how many sessions wait on you.
struct ProjectGroupHeader: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs
    let group: ProjectGroup
    let paths: [String]
    let collapsed: Bool
    @State private var hovering = false
    @State private var dropTargeted = false

    private static let maxTiles = 6

    var body: some View {
        let attention = collapsed ? tabs.attention(in: Set(paths)) : HiddenAttention()
        HStack(spacing: 6) {
            Text(group.name.uppercased())
                .font(.system(size: 11, weight: .bold)).tracking(0.5)
                .foregroundStyle(.secondary).lineLimit(1)
            Text("\(paths.count)").font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            if collapsed && !paths.isEmpty {
                HStack(spacing: 3) {
                    ForEach(paths.prefix(Self.maxTiles), id: \.self) { ProjectIcon(project: Project(path: $0), size: 12) }
                    if paths.count > Self.maxTiles {
                        Text("+\(paths.count - Self.maxTiles)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 2)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            if !attention.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(attention.color).frame(width: 7, height: 7)
                    Text(attention.summary)
                }
                .font(.caption2.weight(.medium)).foregroundStyle(attention.color)
            }
            Menu { GroupMenu(group: group) } label: { Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Group actions")
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .animation(.snappy(duration: 0.2), value: collapsed)
                .padding(.trailing, 8)
        }
        .textCase(nil)
        .padding(.leading, 2)
        .padding(.top, 8).padding(.bottom, 2)
        .contentShape(Rectangle())
        .onTapGesture { sessions.setCollapsed(group: group.id, !collapsed) }
        .onHover { hovering = $0 }
        .help(collapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
        .contextMenu { GroupMenu(group: group) }
        .draggable(ProjectGroupDrag.payload(group.id))
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first else { return false }
            if let moved = ProjectGroupDrag.groupId(item) {
                sessions.moveGroup(moved, before: group.id)
            } else {
                guard !SessionStore.isChats(item) else { return false }
                sessions.move(project: item, toGroup: group.id)
            }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay(alignment: .top) { if dropTargeted { Rectangle().fill(Color.accent).frame(height: 2) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name) group, \(paths.count) projects" + (attention.isEmpty ? "" : ", \(attention.spoken)"))
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: collapsed ? "Expand \(group.name)" : "Collapse \(group.name)") {
            sessions.setCollapsed(group: group.id, !collapsed)
        }
    }
}

/// Stands in for an empty group's projects, so a new group says how to fill it.
struct EmptyGroupRow: View {
    var body: some View {
        Text("Drag a project here, or use Move to Group in its menu.")
            .font(.caption).foregroundStyle(.secondary)
            .padding(.vertical, 3).padding(.leading, 2)
    }
}

/// The group header's ⋯, its context menu and its chip's context menu.
struct GroupMenu: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(WindowState.self) private var window
    let group: ProjectGroup

    var body: some View {
        let index = sessions.groups.firstIndex { $0.id == group.id } ?? 0
        Button("Show Only \u{201C}\(group.name)\u{201D}") { window.groupScope = group.id }
            .disabled(window.activeGroupScope(in: sessions) == group.id)
        Button("Rename Group\u{2026}") { GroupActions.rename(group, sessions: sessions) }
        Divider()
        Button("Move Up") { sessions.moveGroup(group.id, by: -1) }.disabled(index == 0)
        Button("Move Down") { sessions.moveGroup(group.id, by: 1) }.disabled(index >= sessions.groups.count - 1)
        Divider()
        // Only the grouping goes: its projects become ungrouped and keep everything else.
        Button("Delete Group") { sessions.deleteGroup(group.id) }
    }
}

/// "Move to Group ▸" in a project's menu (ADR-210). Chats never joins a group.
struct MoveToGroupMenu: View {
    @Environment(SessionStore.self) private var sessions
    let project: Project

    var body: some View {
        if !SessionStore.isChats(project.path) {
            Menu("Move to Group") { MoveToGroupItems(project: project) }
        }
    }
}

/// The groups to move a project into, New Group… and Remove from Group: the project menu's submenu and
/// the header's quick action (ADR-211) both list these.
struct MoveToGroupItems: View {
    @Environment(SessionStore.self) private var sessions
    let project: Project

    var body: some View {
        let current = sessions.group(of: project.path)?.id
        ForEach(sessions.groups) { group in
            Toggle(group.name, isOn: Binding(get: { current == group.id },
                                             set: { _ in sessions.move(project: project.path, toGroup: group.id) }))
        }
        if !sessions.groups.isEmpty { Divider() }
        Button("New Group\u{2026}") { GroupActions.newGroup(sessions: sessions, with: [project.path]) }
        if current != nil {
            Button("Remove from Group") { sessions.move(project: project.path, toGroup: nil) }
        }
    }
}

/// View ▸ Project Group (ADR-210): the active window's scope, with the rebindable steppers.
struct ProjectGroupScopeItems: View {
    let sessions: SessionStore
    let window: WindowState
    let key: (ShortcutAction) -> KeyboardShortcut?

    var body: some View {
        let scope = window.activeGroupScope(in: sessions)
        Toggle("All Projects", isOn: Binding(get: { scope == nil }, set: { _ in window.groupScope = nil }))
        ForEach(sessions.groups) { group in
            Toggle(group.name, isOn: Binding(get: { scope == group.id }, set: { _ in window.groupScope = group.id }))
        }
        Divider()
        Button("Next Group") { GroupActions.cycleScope(window, sessions: sessions, by: 1) }
            .keyboardShortcut(key(.nextProjectGroup)).disabled(sessions.groups.isEmpty)
        Button("Previous Group") { GroupActions.cycleScope(window, sessions: sessions, by: -1) }
            .keyboardShortcut(key(.previousProjectGroup)).disabled(sessions.groups.isEmpty)
        Divider()
        Button("New Group\u{2026}") { GroupActions.newGroup(sessions: sessions) }
    }
}
