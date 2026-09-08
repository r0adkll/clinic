import Foundation

/// Which projects the sidebar shows, and in what order (ADR-077).
///
/// Membership is sticky: a project stays listed once it has been registered, even when every
/// session in it is archived (ADR-030), until it is removed or unregistered. Order is the order
/// projects were registered, oldest first, so a project never moves on its own; paths the user
/// dragged into place (`ClinicState.projectOrder`, ADR-062) come first in that order, and pinned
/// paths — the Chats group (ADR-068) — are always listed, before everything.
public enum ProjectRoster {
    public struct Inputs: Sendable {
        /// `ClinicState.projectsAddedAt`: every project Clinic has seen, and when it first saw it.
        public var registered: [String: Date]
        /// Projects reachable only through their sessions, with the earliest session date seen.
        /// Used both as membership (a discovered project, or one whose registration was dropped by
        /// Archive Project and is coming back with an unarchived session) and as a fallback date.
        public var withSessions: [String: Date]
        public var removed: Set<String>
        public var manualOrder: [String]
        /// Groups Clinic owns rather than the user (the Chats scratch space, ADR-068): always
        /// listed, before everything, empty or not, and not removable.
        public var pinnedFirst: Set<String>

        public init(registered: [String: Date] = [:], withSessions: [String: Date] = [:],
                    removed: Set<String> = [], manualOrder: [String] = [], pinnedFirst: Set<String> = []) {
            self.registered = registered; self.withSessions = withSessions
            self.removed = removed; self.manualOrder = manualOrder; self.pinnedFirst = pinnedFirst
        }
    }

    public static func paths(_ i: Inputs) -> [String] {
        var addedAt = i.withSessions
        for (path, date) in i.registered { addedAt[path] = date }   // a registration beats a session's date
        for path in i.removed where !i.pinnedFirst.contains(path) { addedAt[path] = nil }
        for path in i.pinnedFirst where addedAt[path] == nil { addedAt[path] = .distantPast }

        let byDate: (String, String) -> Bool = { (addedAt[$0]!, $0) < (addedAt[$1]!, $1) }
        let pinned = addedAt.keys.filter { i.pinnedFirst.contains($0) }.sorted(by: byDate)
        var seen = Set(pinned)
        let manual = i.manualOrder.filter { addedAt[$0] != nil && seen.insert($0).inserted }
        let rest = addedAt.keys.filter { !seen.contains($0) }.sorted(by: byDate)
        return pinned + manual + rest
    }
}
