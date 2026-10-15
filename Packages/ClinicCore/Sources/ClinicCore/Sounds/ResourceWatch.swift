import Foundation

/// Turns the status line's numbers into the moments a pack voices as `resource.limit` (ADR-203).
///
/// The status line reports many times a turn, so a limit is a crossing, not a level: context sounds once
/// on the way past 90 % and is armed again only once it falls below 80 % (a compaction, a `/clear`); the
/// plan's five-hour window sounds once per window, which its reset time names.
public struct ResourceWatch: Sendable {
    public static let contextAt = 90.0
    public static let contextRearm = 80.0
    public static let planAt = 90.0

    private var contextSpoken: Set<String> = []
    private var planSpokenFor: Date?

    public init() {}

    /// True when this report carries the session's context past the line.
    public mutating func context(_ percentage: Double?, session: String) -> Bool {
        guard let percentage else { return false }
        if percentage < Self.contextRearm { contextSpoken.remove(session); return false }
        guard percentage >= Self.contextAt, !contextSpoken.contains(session) else { return false }
        contextSpoken.insert(session)
        return true
    }

    /// True the first time a five-hour window is seen past the line.
    public mutating func plan(_ window: StatusLineReport.RateWindow?) -> Bool {
        guard let window, window.usedPercentage >= Self.planAt, planSpokenFor != window.resetsAt else { return false }
        planSpokenFor = window.resetsAt
        return true
    }

    public mutating func forget(session: String) { contextSpoken.remove(session) }

    /// Whether a turn's failure is a limit rather than an error, from the words the CLI used.
    public static func isLimit(_ message: String?) -> Bool {
        guard let text = message?.lowercased() else { return false }
        return ["rate limit", "rate_limit", "usage limit", "usage_limit", "429", "quota"].contains { text.contains($0) }
    }
}
