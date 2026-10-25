import Foundation

/// A session's pull requests as its footer tray and card list them (ADR-230): the layers of one stack
/// together, bottom first, and every other pull request on its own.
///
/// A stack is GitHub's own where GitHub reports one (ADR-163), else a branch chain: pull requests in one
/// repository where each targets the head branch of another. GitHub has no stack for a chain built by hand,
/// but it lands the same way, so it is drawn the same way. Grouping is only for display; the merge box goes
/// on trusting GitHub's stack alone.
public struct PullRequestGroup: Hashable, Sendable, Identifiable {
    /// Bottom layer first. One ref for a pull request on its own.
    public var refs: [PullRequestRef]
    /// The branch a stack lands on; nil for a pull request on its own.
    public var base: String?

    public init(refs: [PullRequestRef], base: String? = nil) {
        self.refs = refs; self.base = refs.count > 1 ? base : nil
    }

    public var id: String { refs.first?.id ?? "" }
    public var isStack: Bool { refs.count > 1 }

    /// The base and head branch of a pull request that has been read.
    public struct Branches: Hashable, Sendable {
        public var base: String
        public var head: String
        public init(base: String, head: String) { self.base = base; self.head = head }
    }

    /// Groups `refs`, which run oldest mention first, into stacks and single pull requests. Groups keep that
    /// order, each placed by its most recently mentioned member. GitHub's stacks are gathered first; what
    /// is left is chained where one pull request's base is exactly one other's head in the same repository.
    /// A pull request joins the chain under it only when nothing else in the session sits on that layer too,
    /// so a fork starts groups of its own rather than drawing a tree as a list. One not read yet stands alone.
    public static func grouped(_ refs: [PullRequestRef],
                               branches: (PullRequestRef) -> Branches?,
                               stacks: (PullRequestRef) -> PullRequestStack?) -> [PullRequestGroup] {
        var groups: [(group: PullRequestGroup, newest: Int)] = []
        var placed = Set<String>()
        let index = Dictionary(refs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
        let newest = { (members: [PullRequestRef]) in members.compactMap { index[$0.id] }.max() ?? 0 }
        let repository = { (ref: PullRequestRef) in "\(ref.host)/\(ref.repository)" }

        // GitHub's stacks, by position.
        for ref in refs where !placed.contains(ref.id) {
            guard let stack = stacks(ref) else { continue }
            let key = "\(repository(ref))#\(stack.number)"
            let members = refs
                .filter { other in !placed.contains(other.id) && stacks(other).map { "\(repository(other))#\($0.number)" } == key }
                .sorted { (stacks($0)?.position ?? 0) < (stacks($1)?.position ?? 0) }
            placed.formUnion(members.map(\.id))
            groups.append((PullRequestGroup(refs: members, base: stack.baseRefName), newest(members)))
        }

        // Branch chains among the rest.
        var unique = Set<String>()
        let rest = refs.filter { !placed.contains($0.id) && unique.insert($0.id).inserted }
        // The one pull request whose head `ref` targets; none when no other, or more than one, has that head.
        var parents: [String: PullRequestRef] = [:]
        for ref in rest {
            guard let base = branches(ref)?.base, !base.isEmpty else { continue }
            let under = rest.filter { $0.id != ref.id && repository($0) == repository(ref) && branches($0)?.head == base }
            if under.count == 1 { parents[ref.id] = under[0] }
        }
        let children = Dictionary(grouping: rest.filter { parents[$0.id] != nil }) { parents[$0.id]!.id }
        // The layer under `ref` in its chain: its parent, when `ref` is that parent's only child.
        func below(_ ref: PullRequestRef) -> PullRequestRef? {
            guard let p = parents[ref.id], children[p.id]?.count == 1 else { return nil }
            return p
        }
        for ref in rest where !placed.contains(ref.id) {
            var bottom = ref
            var seen: Set<String> = [ref.id]
            while let next = below(bottom), !seen.contains(next.id), !placed.contains(next.id) {
                bottom = next; seen.insert(next.id)
            }
            var chain = [bottom]
            placed.insert(bottom.id)
            while let up = children[chain[chain.count - 1].id], up.count == 1, !placed.contains(up[0].id) {
                chain.append(up[0]); placed.insert(up[0].id)
            }
            groups.append((PullRequestGroup(refs: chain, base: branches(bottom)?.base), newest(chain)))
        }

        return groups.sorted { $0.newest < $1.newest }.map(\.group)
    }
}

/// How a session's pull requests stand, for the card's summary row and the footer chip's help (ADR-230).
/// One not read yet (a nil mark) counts as open, as ADR-228 counts it.
public struct PullRequestTally: Equatable, Sendable {
    public var open = 0
    /// Open, with a failing check.
    public var failing = 0
    /// Open, with a check still running.
    public var running = 0
    /// Merged or closed.
    public var finished = 0

    public init(_ marks: [PullRequestMark?]) {
        for mark in marks {
            guard (mark?.state ?? .open) == .open else { finished += 1; continue }
            open += 1
            switch mark?.attention {
            case .checksFailing: failing += 1
            case .checksPending: running += 1
            default: break
            }
        }
    }

    /// "5 failing · 1 running", nil when no check is failing or running.
    public var detail: String? {
        let parts = [failing > 0 ? "\(failing) failing" : nil, running > 0 ? "\(running) running" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
