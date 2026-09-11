import Foundation

/// The few tasks a project's new-session composer offers as quick starts (ADR-117). Pure, over the
/// same normalized items and viewer facts the Tasks screen filters, so every provider gets it free.
public enum WorkItemSuggestions {
    /// Open items worth starting a session on, best first:
    /// 1. assigned to you;
    /// 2. mentioning you, or filed by you;
    /// 3. assigned to nobody.
    ///
    /// Each tier is ordered by last update. Left out: closed items, items that already have a session
    /// (`linked`, by item id), and items assigned only to other people — their work, not a suggestion.
    /// While the viewer on a host is unknown, nothing there can be told apart, so its open items all
    /// rank by recency alone.
    public static func rank(_ items: [WorkItem], context: WorkItemFilter.Context, linked: Set<String> = [], limit: Int = 3) -> [WorkItem] {
        let ranked: [(tier: Int, item: WorkItem)] = items.compactMap { item in
            guard item.state == .open, !linked.contains(item.id) else { return nil }
            guard let tier = tier(of: item, context: context) else { return nil }
            return (tier, item)
        }
        return ranked
            .sorted { a, b in
                if a.tier != b.tier { return a.tier < b.tier }
                if a.item.updatedAt != b.item.updatedAt { return a.item.updatedAt > b.item.updatedAt }
                return a.item.id < b.item.id
            }
            .prefix(limit).map(\.item)
    }

    /// 0 best; nil = leave it out.
    static func tier(of item: WorkItem, context: WorkItemFilter.Context) -> Int? {
        guard let me = context.viewers[item.ref.source.host] else { return 2 }
        if item.assignees.contains(where: { WorkItemFilter.same($0, me) }) { return 0 }
        guard item.assignees.isEmpty else { return nil }
        if context.mentioned.contains(item.id) || WorkItemFilter.same(item.author, me) { return 1 }
        return 2
    }
}
