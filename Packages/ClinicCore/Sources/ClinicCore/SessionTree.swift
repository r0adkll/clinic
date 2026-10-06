import Foundation

/// Who a session came out of (ADR-181). Clinic's record: the CLI writes nothing that links a fork or a
/// spawned session to its parent, so this is written at the moment Clinic launches the child.
public struct SessionParent: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// `claude --resume <parent> --fork-session`: the child inherits the parent's conversation.
        case fork
        /// A fresh session the parent (or the user, under the parent) asked for, with a prompt.
        case spawn
    }

    public var id: SessionID
    public var kind: Kind
    public var since: Date

    public init(id: SessionID, kind: Kind, since: Date = Date()) {
        self.id = id; self.kind = kind; self.since = since
    }
}

/// Lays a project's sessions out as a tree (ADR-181). Pure: the stores hand it what is visible and it
/// says what to draw, in what order, at what depth.
public enum SessionTree {
    /// One visible session, wherever its project is.
    public struct Item: Sendable, Equatable {
        public var id: SessionID
        public var projectPath: String
        /// What the row sorts by: last activity, or creation under the *created* sort (ADR-040).
        public var sortKey: Date
        /// Whether the row itself matches the sidebar filter. `true` for every row when nothing is typed.
        public var matches: Bool

        public init(id: SessionID, projectPath: String, sortKey: Date, matches: Bool = true) {
            self.id = id; self.projectPath = projectPath; self.sortKey = sortKey; self.matches = matches
        }
    }

    /// One row of the laid-out tree.
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: SessionID
        /// 0 for a root; each level indents once more.
        public var depth: Int
        /// The relationship to the row above it in the tree, if any.
        public var parent: SessionParent?
        /// Whether anything hangs under it (shown or folded).
        public var hasChildren: Bool
        /// Descendants hidden because this row is collapsed; empty when expanded or childless.
        public var folded: [SessionID]
        /// Drawn only because something under it matches the filter; the row itself does not.
        public var isContext: Bool

        public init(id: SessionID, depth: Int, parent: SessionParent? = nil, hasChildren: Bool = false,
                    folded: [SessionID] = [], isContext: Bool = false) {
            self.id = id; self.depth = depth; self.parent = parent; self.hasChildren = hasChildren
            self.folded = folded; self.isContext = isContext
        }
    }

    /// The rows for one project's section, newest subtree first.
    ///
    /// - A session with a visible parent is drawn under that parent, in the parent's project, whatever
    ///   its own `projectPath` says; a session whose parent is not among `items` is a root of its own.
    /// - A subtree is placed by the newest `sortKey` anywhere in it; siblings order the same way.
    /// - A collapsed row keeps its descendants in `folded` instead of emitting them, unless `filtering`,
    ///   when folding is suspended (as it is for projects).
    /// - When `filtering`, a row is emitted if it or any descendant matches; a non-matching ancestor is
    ///   emitted as context.
    /// - A cycle in `parents` (which Clinic never writes, but a state file could carry) is broken at the
    ///   first repeated id: that session is treated as a root.
    public static func rows(project: String, items: [Item], parents: [SessionID: SessionParent],
                            collapsed: Set<SessionID> = [], filtering: Bool = false) -> [Row] {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The parent a row hangs under: present, visible, not itself, and not part of a cycle.
        var effectiveParent: [SessionID: SessionID] = [:]
        for item in items {
            guard let p = parents[item.id]?.id, p != item.id, byId[p] != nil else { continue }
            var seen: Set<SessionID> = [item.id]
            var cursor: SessionID? = p
            var cyclic = false
            while let c = cursor {
                if seen.contains(c) { cyclic = true; break }
                seen.insert(c)
                cursor = parents[c].flatMap { byId[$0.id] != nil && $0.id != c ? $0.id : nil }
            }
            if !cyclic { effectiveParent[item.id] = p }
        }
        var children: [SessionID: [SessionID]] = [:]
        for (child, parent) in effectiveParent { children[parent, default: []].append(child) }

        var keyMemo: [SessionID: Date] = [:]
        func subtreeKey(_ id: SessionID) -> Date {
            if let k = keyMemo[id] { return k }
            var k = byId[id]?.sortKey ?? .distantPast
            for c in children[id] ?? [] { k = max(k, subtreeKey(c)) }
            keyMemo[id] = k
            return k
        }
        var matchMemo: [SessionID: Bool] = [:]
        func subtreeMatches(_ id: SessionID) -> Bool {
            if let m = matchMemo[id] { return m }
            var m = byId[id]?.matches ?? false
            if !m { m = (children[id] ?? []).contains { subtreeMatches($0) } }
            matchMemo[id] = m
            return m
        }
        func descendants(_ id: SessionID) -> [SessionID] {
            (children[id] ?? []).flatMap { [$0] + descendants($0) }
        }
        func ordered(_ ids: [SessionID]) -> [SessionID] {
            ids.sorted { (subtreeKey($0), $0.rawValue) > (subtreeKey($1), $1.rawValue) }
        }

        var out: [Row] = []
        func emit(_ id: SessionID, depth: Int) {
            if filtering, !subtreeMatches(id) { return }
            let kids = children[id] ?? []
            let folds = !filtering && collapsed.contains(id) && !kids.isEmpty
            out.append(Row(id: id, depth: depth, parent: effectiveParent[id] != nil ? parents[id] : nil,
                           hasChildren: !kids.isEmpty, folded: folds ? ordered(descendants(id)) : [],
                           isContext: filtering && !(byId[id]?.matches ?? false)))
            guard !folds else { return }
            for c in ordered(kids) { emit(c, depth: depth + 1) }
        }
        let roots = items.filter { $0.projectPath == project && effectiveParent[$0.id] == nil }.map(\.id)
        for r in ordered(roots) { emit(r, depth: 0) }
        return out
    }

    /// Every session under `id`, by the raw parent map (visible or not), nearest first. For archiving a
    /// subtree. Cycles are cut by the visited set.
    public static func descendants(of id: SessionID, parents: [SessionID: SessionParent]) -> [SessionID] {
        var children: [SessionID: [SessionID]] = [:]
        for (child, p) in parents where child != p.id { children[p.id, default: []].append(child) }
        var out: [SessionID] = []
        var seen: Set<SessionID> = [id]
        var queue = (children[id] ?? []).sorted { $0.rawValue < $1.rawValue }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard !seen.contains(next) else { continue }
            seen.insert(next)
            out.append(next)
            queue += (children[next] ?? []).sorted { $0.rawValue < $1.rawValue }
        }
        return out
    }
}
