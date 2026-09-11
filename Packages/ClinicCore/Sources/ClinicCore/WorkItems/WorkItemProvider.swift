import Foundation

/// A tracker Clinic can list work items from (ADR-113). GitHub is the only one today; GitLab would be
/// a second conformance over `glab`, and nothing above this protocol would change.
///
/// Providers return normalized `WorkItem`s. Filtering, search, sorting and counting happen once, over
/// those, in `WorkItemFilter` — a provider never implements a filter.
public protocol WorkItemProvider: Sendable {
    /// Matches `WorkItemSource.provider` for every source this provider resolves.
    var kind: String { get }

    /// Whether the provider's CLI is installed and logged in (ADR-086's split, for every provider).
    func availability() async -> ToolAvailability

    /// The signed-in user on `host`, for "Assigned to me" and "Created by me". Nil when unknown.
    func viewerLogin(host: String) async -> String?

    /// The sources a project folder points at, or why it points at none.
    func resolveSources(projectPath: String) async -> WorkItemSourceResolution

    /// One source's items in `state`, most recently updated first, stopping at `limit`.
    func list(_ source: WorkItemSource, state: WorkItemState, limit: Int) async throws -> WorkItemPage

    /// Open items on `host` that mention the signed-in user. Intersected with known sources by the caller.
    func mentioningViewer(host: String) async throws -> [WorkItemRef]

    /// Rendered body, thread and linked pull requests for one item.
    func detail(_ ref: WorkItemRef) async throws -> WorkItemDetail

    /// The first prompt of a session started from `item` (ADR-114). Provider-specific because it tells
    /// Claude which CLI reads the item.
    func sessionPrompt(for item: WorkItem) -> String
}

public enum WorkItemSourceResolution: Hashable, Sendable {
    case resolved([WorkItemSource])
    /// Short and human: "No GitHub remote", "Not a git repository".
    case unresolved(reason: String)

    public var sources: [WorkItemSource] {
        if case .resolved(let s) = self { return s }
        return []
    }
    public var reason: String? {
        if case .unresolved(let r) = self { return r }
        return nil
    }
}

/// One `list` result: the items and whether `limit` cut the source short.
public struct WorkItemPage: Hashable, Sendable {
    public var items: [WorkItem]
    public var truncated: Bool
    public init(items: [WorkItem], truncated: Bool) { self.items = items; self.truncated = truncated }
}

/// The worktree and branch name a session started from an item gets (ADR-114): `issue-123-short-slug`.
public enum WorkItemBranch {
    public static func name(for item: WorkItem, maxSlug: Int = 40) -> String {
        let slug = slug(item.title, max: maxSlug)
        return slug.isEmpty ? "issue-\(item.ref.number)" : "issue-\(item.ref.number)-\(slug)"
    }

    /// Lowercase ASCII letters and digits; every other run becomes one `-`; cut at a word boundary.
    static func slug(_ title: String, max: Int) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            let isWordChar = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isWordChar {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        guard out.count > max else { return out }
        let cut = String(out.prefix(max))
        // A cut that lands exactly between two words keeps the whole of the first.
        if out[out.index(out.startIndex, offsetBy: max)] == "-" { return cut }
        // Otherwise back up to the last whole word, unless that would leave nothing.
        if let dash = cut.lastIndex(of: "-"), dash > cut.startIndex { return String(cut[..<dash]) }
        return cut
    }
}
