import Foundation

/// Everything the Tasks screen narrows, orders and counts by (ADR-112), as one pure value over
/// normalized `WorkItem`s. Providers never filter (ADR-113); a second provider inherits all of this.
///
/// The project is deliberately not in here: it is a scope over *sources*, applied by the caller,
/// because counting per project means applying everything else first.
public struct WorkItemFilter: Codable, Hashable, Sendable {
    public enum View: String, Codable, CaseIterable, Sendable, Identifiable {
        case assigned, created, mentioned, all
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .assigned: "Assigned to Me"
            case .created: "Created by Me"
            case .mentioned: "Mentioned"
            case .all: "All"
            }
        }
    }

    public enum StateFilter: String, Codable, CaseIterable, Sendable, Identifiable {
        case open, closed, all
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
        public var includesClosed: Bool { self != .open }
    }

    public enum Sort: String, Codable, CaseIterable, Sendable, Identifiable {
        case updated, created, comments, number
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .updated: "Recently Updated"
            case .created: "Newest"
            case .comments: "Most Commented"
            case .number: "Number"
            }
        }
    }

    public enum Grouping: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, project
        public var id: String { rawValue }
        public var title: String { self == .none ? "None" : "Project" }
    }

    /// The facts about the viewer a view needs: who is signed in on each host, and which items
    /// mention them (the list query has no mentions field, so this comes from a search, ADR-113).
    public struct Context: Sendable {
        public var viewers: [String: String]
        public var mentioned: Set<String>
        public init(viewers: [String: String] = [:], mentioned: Set<String> = []) { self.viewers = viewers; self.mentioned = mentioned }
    }

    /// `assignee` value meaning "nobody is assigned".
    public static let unassigned = ""

    public var view: View = .assigned
    public var state: StateFilter = .open
    public var text = ""
    /// Label names, matched case-insensitively. An item must carry every one (GitHub's `label:a label:b`).
    public var labels: Set<String> = []
    public var assignee: String?
    public var author: String?
    public var milestone: String?
    public var sort: Sort = .updated
    public var grouping: Grouping = .none

    public init() {}

    private enum CodingKeys: String, CodingKey { case view, state, text, labels, assignee, author, milestone, sort, grouping }

    /// Tolerant: a saved filter from an older build keeps whatever it still has.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        view = (try? c.decodeIfPresent(View.self, forKey: .view)) ?? .assigned
        state = (try? c.decodeIfPresent(StateFilter.self, forKey: .state)) ?? .open
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        labels = (try? c.decodeIfPresent(Set<String>.self, forKey: .labels)) ?? []
        assignee = try? c.decodeIfPresent(String.self, forKey: .assignee)
        author = try? c.decodeIfPresent(String.self, forKey: .author)
        milestone = try? c.decodeIfPresent(String.self, forKey: .milestone)
        sort = (try? c.decodeIfPresent(Sort.self, forKey: .sort)) ?? .updated
        grouping = (try? c.decodeIfPresent(Grouping.self, forKey: .grouping)) ?? .none
    }

    /// True when anything beyond view, state, sort and grouping narrows the list — what "Clear" resets.
    public var hasRefinements: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || !labels.isEmpty || assignee != nil || author != nil || milestone != nil
    }

    public mutating func clearRefinements() {
        text = ""; labels = []; assignee = nil; author = nil; milestone = nil
    }

    // MARK: Matching

    public func matches(_ item: WorkItem, context: Context) -> Bool {
        Self.matches(item, view: view, context: context) && matchesRefinements(item)
    }

    public static func matches(_ item: WorkItem, view: View, context: Context) -> Bool {
        switch view {
        case .all: return true
        case .mentioned: return context.mentioned.contains(item.id)
        case .assigned:
            guard let me = context.viewers[item.ref.source.host] else { return false }
            return item.assignees.contains { same($0, me) }
        case .created:
            guard let me = context.viewers[item.ref.source.host] else { return false }
            return same(item.author, me)
        }
    }

    /// State, search, labels, assignee, author and milestone — everything but the view.
    public func matchesRefinements(_ item: WorkItem) -> Bool {
        switch state {
        case .open: if item.state != .open { return false }
        case .closed: if item.state != .closed { return false }
        case .all: break
        }
        if !labels.isEmpty {
            for wanted in labels where !item.labels.contains(where: { Self.same($0.name, wanted) }) { return false }
        }
        if let assignee {
            if assignee == Self.unassigned { if !item.assignees.isEmpty { return false } }
            else if !item.assignees.contains(where: { Self.same($0, assignee) }) { return false }
        }
        if let author, !Self.same(item.author, author) { return false }
        if let milestone, !Self.same(item.milestone ?? "", milestone) { return false }
        return Self.matchesText(item, text)
    }

    /// Every whitespace-separated term must match. `#123` matches the number exactly; any other term
    /// is a case-insensitive substring of the title, body, `owner/repo` or author.
    public static func matchesText(_ item: WorkItem, _ text: String) -> Bool {
        for term in text.split(whereSeparator: \.isWhitespace) {
            if term.hasPrefix("#"), let n = Int(term.dropFirst()) {
                if item.ref.number != n { return false }
                continue
            }
            let t = String(term)
            let hit = [item.title, item.ref.source.scope, item.author, item.body].contains {
                $0.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            if !hit { return false }
        }
        return true
    }

    // MARK: Applying

    /// Matching items in this filter's order.
    public func apply(_ items: [WorkItem], context: Context) -> [WorkItem] {
        Self.sorted(items.filter { matches($0, context: context) }, by: sort)
    }

    /// Descending by the key; ties fall back to recency, then identity, so the order never flickers.
    public static func sorted(_ items: [WorkItem], by sort: Sort) -> [WorkItem] {
        items.sorted { a, b in
            switch sort {
            case .updated: if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            case .created: if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            case .comments: if a.commentCount != b.commentCount { return a.commentCount > b.commentCount }
            case .number: if a.ref.number != b.ref.number { return a.ref.number > b.ref.number }
            }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.id < b.id
        }
    }

    /// How many items each view would show under the current refinements (the scope column's counts).
    public func viewCounts(_ items: [WorkItem], context: Context) -> [View: Int] {
        let refined = items.filter(matchesRefinements)
        var out: [View: Int] = [:]
        for v in View.allCases { out[v] = refined.filter { Self.matches($0, view: v, context: context) }.count }
        return out
    }

    /// How many items each source would show under the current view and refinements.
    public func sourceCounts(_ items: [WorkItem], context: Context) -> [String: Int] {
        var out: [String: Int] = [:]
        for item in items where matches(item, context: context) { out[item.ref.source.id, default: 0] += 1 }
        return out
    }

    static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
}

/// The values a filter menu offers, merged by name across sources (ADR-112): two repositories' `bug`
/// labels are one entry. First-seen spelling and colour win.
public struct WorkItemFacets: Equatable, Sendable {
    public var labels: [WorkItemLabel]
    public var assignees: [String]
    public var authors: [String]
    public var milestones: [String]

    public init(_ items: [WorkItem]) {
        var labels: [String: WorkItemLabel] = [:], assignees: [String: String] = [:]
        var authors: [String: String] = [:], milestones: [String: String] = [:]
        for item in items {
            for l in item.labels where labels[l.name.lowercased()] == nil { labels[l.name.lowercased()] = l }
            for a in item.assignees where assignees[a.lowercased()] == nil { assignees[a.lowercased()] = a }
            if authors[item.author.lowercased()] == nil { authors[item.author.lowercased()] = item.author }
            if let m = item.milestone, milestones[m.lowercased()] == nil { milestones[m.lowercased()] = m }
        }
        func ordered(_ d: [String: String]) -> [String] { d.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
        self.labels = labels.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.assignees = ordered(assignees)
        self.authors = ordered(authors)
        self.milestones = ordered(milestones)
    }
}
