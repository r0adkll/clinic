import Foundation

/// A named set of projects the sidebar shows under one caption, and that a window can be scoped to
/// (ADR-210). The user makes them; nothing is grouped automatically.
public struct ProjectGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Project paths. Their order in the sidebar is the roster's, not this set's.
    public var members: Set<String>

    public init(id: UUID = UUID(), name: String, members: Set<String> = []) {
        self.id = id; self.name = name; self.members = members
    }
}

/// Where each project goes in the sidebar, given the roster's order and the groups (ADR-210).
public struct ProjectLayout: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        public var group: ProjectGroup
        public var paths: [String]
    }

    /// Clinic's own groups (Chats), listed first in every scope.
    public var pinned: [String]
    /// Projects in no group, under Chats and above the groups. Empty when scoped to a group.
    public var ungrouped: [String]
    /// The groups in their own order, each with its members in roster order; only the scoped one
    /// when there is a scope. A group with no listed members is still here, so it can be dropped on.
    public var groups: [Section]

    /// Every project, in the order the sidebar lists them.
    public var allPaths: [String] { pinned + ungrouped + groups.flatMap(\.paths) }

    /// - Parameters:
    ///   - paths: the roster's order (`ProjectRoster.paths`).
    ///   - pinned: paths that are never grouped (Chats).
    ///   - scope: a group id to show only that group; nil, or an id that no longer exists, shows all.
    public init(paths: [String], groups: [ProjectGroup], pinned: Set<String>, scope: UUID? = nil) {
        let scoped = groups.first { $0.id == scope }
        let grouped = Dictionary(groups.flatMap { g in g.members.map { ($0, g.id) } }, uniquingKeysWith: { first, _ in first })
        self.pinned = paths.filter { pinned.contains($0) }
        let rest = paths.filter { !pinned.contains($0) }
        ungrouped = scoped == nil ? rest.filter { grouped[$0] == nil } : []
        self.groups = (scoped.map { [$0] } ?? groups).map { g in Section(group: g, paths: rest.filter { grouped[$0] == g.id }) }
    }
}

extension ClinicState {
    /// The group a project is in, if any. A project is in at most one (ADR-210).
    public func group(of path: String) -> ProjectGroup? { projectGroups.first { $0.members.contains(path) } }

    /// Adds a group at the end, holding `paths` (taken out of any group they were in). Returns its id.
    /// Pass `id` when the same change is applied twice (in memory, then on disk) so both agree.
    @discardableResult
    public mutating func addGroup(id: UUID = UUID(), named name: String, with paths: [String] = []) -> UUID {
        let group = ProjectGroup(id: id, name: Self.groupName(name))
        projectGroups.append(group)
        for path in paths { move(project: path, toGroup: group.id) }
        return group.id
    }

    public mutating func renameGroup(_ id: UUID, to name: String) {
        guard let i = projectGroups.firstIndex(where: { $0.id == id }) else { return }
        projectGroups[i].name = Self.groupName(name)
    }

    /// Deletes the group only: its projects become ungrouped, and nothing else about them changes.
    public mutating func deleteGroup(_ id: UUID) {
        projectGroups.removeAll { $0.id == id }
        collapsedGroups.remove(id)
    }

    /// Puts `path` in group `id`, taking it out of any other; nil ungroups it. An unknown id ungroups too,
    /// so a project is never left pointing at a group that is gone.
    public mutating func move(project path: String, toGroup id: UUID?) {
        for i in projectGroups.indices { projectGroups[i].members.remove(path) }
        guard let id, let i = projectGroups.firstIndex(where: { $0.id == id }) else { return }
        projectGroups[i].members.insert(path)
    }

    /// Moves group `id` to `target`'s position.
    public mutating func moveGroup(_ id: UUID, before target: UUID) {
        guard id != target, let from = projectGroups.firstIndex(where: { $0.id == id }) else { return }
        let group = projectGroups.remove(at: from)
        let to = projectGroups.firstIndex(where: { $0.id == target }) ?? projectGroups.endIndex
        projectGroups.insert(group, at: to)
    }

    /// Moves group `id` one place up (`by: -1`) or down (`by: 1`).
    public mutating func moveGroup(_ id: UUID, by offset: Int) {
        guard let from = projectGroups.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard projectGroups.indices.contains(to) else { return }
        projectGroups.swapAt(from, to)
    }

    static func groupName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Group" : trimmed
    }
}
