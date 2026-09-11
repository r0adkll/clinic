import Foundation

/// One source's open items as last fetched, plus what only Clinic knows about them (ADR-113).
public struct CachedWorkItems: Codable, Equatable, Sendable {
    public var source: WorkItemSource
    public var fetchedAt: Date
    public var items: [WorkItem]
    /// The fetch stopped at the limit; there are more open items than these.
    public var truncated: Bool
    /// When each item (by number) was last selected, for the "updated since you looked" dot (ADR-112).
    public var lastViewed: [Int: Date]

    public init(source: WorkItemSource, fetchedAt: Date, items: [WorkItem], truncated: Bool = false, lastViewed: [Int: Date] = [:]) {
        self.source = source; self.fetchedAt = fetchedAt; self.items = items; self.truncated = truncated; self.lastViewed = lastViewed
    }

    /// True when the item changed after it was last looked at. An item never looked at is not
    /// "unread" — a first load would otherwise light up every row.
    public func isUpdatedSinceViewed(_ item: WorkItem) -> Bool {
        guard let seen = lastViewed[item.ref.number] else { return false }
        return item.updatedAt > seen
    }
}

/// `Application Support/Clinic/work-items/<source>.json`, one file per source (ADR-113). Pure file
/// IO over a directory, so tests point it at a temporary one.
public struct WorkItemCache: Sendable {
    public let directory: URL

    public init(directory: URL = ClinicPaths.directory.appendingPathComponent("work-items", isDirectory: true)) {
        self.directory = directory
    }

    /// `github:github.com/owner/repo` → `github-github.com-owner-repo.json`.
    public func url(for source: WorkItemSource) -> URL {
        let safe = source.id.map { c -> Character in
            c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" ? c : "-"
        }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    public func load(_ source: WorkItemSource) -> CachedWorkItems? {
        guard let data = try? Data(contentsOf: url(for: source)) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        guard let cached = try? d.decode(CachedWorkItems.self, from: data), cached.source == source else { return nil }
        return cached
    }

    public func save(_ cached: CachedWorkItems) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        try e.encode(cached).write(to: url(for: cached.source), options: .atomic)
    }
}
