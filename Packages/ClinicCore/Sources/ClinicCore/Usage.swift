import Foundation

/// Claude plan usage from the CLI's OAuth session (ADR-051). The endpoint is undocumented; parsing is tolerant.
public struct UsageSnapshot: Sendable, Equatable {
    public struct Bar: Sendable, Equatable, Identifiable {
        public var id: String { kind + (modelName ?? "") }
        public var kind: String          // session | weekly_all | weekly_scoped | …
        public var percent: Int          // clamped 0…100
        public var rawPercent: Int
        public var severity: String      // normal | warning | exceeded | …
        public var resetsAt: Date?
        public var modelName: String?
        public var title: String {
            switch kind {
            case "session": return "Session (5h)"
            case "weekly_all": return "Week, all models"
            case "weekly_scoped": return "Week, " + (modelName ?? "scoped")
            default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
        /// Two or three characters for the collapsed snapshot, where a chip gets ~20 pt of label (ADR-085).
        public var shortTitle: String {
            switch kind {
            case "session": return "5h"
            case "weekly_all": return "7d"
            case "weekly_scoped":
                let words = (modelName ?? "").split(separator: " ").filter { $0.caseInsensitiveCompare("claude") != .orderedSame }
                return words.first.map(String.init) ?? "Model"
            default: return title.split(separator: " ").first.map(String.init) ?? kind
            }
        }
    }
    public struct Credits: Sendable, Equatable {
        public var used: Double
        public var limit: Double?
        public var currency: String
        public var spendLimitReached: Bool
    }
    public var bars: [Bar]
    public var credits: Credits?
    public var subscription: String
    public var fetchedAt: Date
    /// When the newest status line window shown in `bars` arrived, if one is (ADR-162).
    public var liveAt: Date? = nil
    /// What the "Updated …" caption means: the fetch or the newest live window, whichever is later.
    public var updatedAt: Date { max(fetchedAt, liveAt ?? .distantPast) }

    static let kindOrder = ["session": 0, "weekly_all": 1, "weekly_scoped": 2]
    static let severityOrder = ["exceeded": 0, "warning": 1]

    /// The `limit` most-pressing bars, back in display order (ADR-085). The collapsed snapshot shows one
    /// chip per limit and drops the calmest first, so an exceeded model-scoped bar survives a narrow sidebar
    /// while a quiet one makes way. Ties break on percent, then on the snapshot's own kind order.
    public func compactBars(limit: Int) -> [Bar] {
        guard limit < bars.count else { return bars }
        return bars.enumerated()
            .sorted { a, b in
                let ra = Self.severityOrder[a.element.severity] ?? 2, rb = Self.severityOrder[b.element.severity] ?? 2
                if ra != rb { return ra < rb }
                if a.element.percent != b.element.percent { return a.element.percent > b.element.percent }
                return a.offset < b.offset
            }
            .prefix(max(0, limit))
            .sorted { $0.offset < $1.offset }
            .map(\.element)
    }

    /// Parses the `/api/oauth/usage` response body.
    public static func parse(_ data: Data, subscription: String = "", now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.malformed }
        var bars: [Bar] = []
        for entry in root["limits"] as? [[String: Any]] ?? [] {
            guard let pct = (entry["percent"] as? NSNumber)?.doubleValue else { continue }
            let raw = Int(pct.rounded())
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            bars.append(Bar(kind: entry["kind"] as? String ?? "", percent: max(0, min(100, raw)), rawPercent: raw,
                            severity: entry["severity"] as? String ?? "normal",
                            resetsAt: (entry["resets_at"] as? String).flatMap(Self.parseDate),
                            modelName: model?["display_name"] as? String))
        }
        bars.sort { (kindOrder[$0.kind] ?? 99) < (kindOrder[$1.kind] ?? 99) }
        var credits: Credits?
        if let extra = root["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            let scale = pow(10.0, Double(extra["decimal_places"] as? Int ?? 0))
            credits = Credits(used: ((extra["used_credits"] as? NSNumber)?.doubleValue ?? 0) / scale,
                              limit: (extra["monthly_limit"] as? NSNumber).map { $0.doubleValue / scale },
                              currency: extra["currency"] as? String ?? "USD",
                              spendLimitReached: extra["spend_limit_reached"] as? Bool ?? false)
        } else if let spend = root["spend"] as? [String: Any], spend["enabled"] as? Bool == true {
            let used = spend["used"] as? [String: Any] ?? [:]
            let scale = pow(10.0, Double(used["exponent"] as? Int ?? 2))
            let limit = spend["limit"] as? [String: Any]
            credits = Credits(used: ((used["amount_minor"] as? NSNumber)?.doubleValue ?? 0) / scale,
                              limit: (limit?["amount_minor"] as? NSNumber).map { $0.doubleValue / scale },
                              currency: used["currency"] as? String ?? "USD",
                              spendLimitReached: (spend["severity"] as? String) == "exceeded")
        }
        return UsageSnapshot(bars: bars, credits: credits, subscription: subscription, fetchedAt: now)
    }

    /// The fetched snapshot with the status line's windows laid over it (ADR-162). A live window replaces
    /// its bar when it arrived after the fetch and has not reset; the model-scoped bars and credits only
    /// the endpoint knows stay as fetched. With nothing fetched — not connected, or before the first poll —
    /// the live windows alone make the snapshot, and with neither there is none.
    public static func combining(_ fetched: UsageSnapshot?, live: LiveRateLimits, now: Date = Date()) -> UsageSnapshot? {
        var snap = fetched ?? UsageSnapshot(bars: [], credits: nil, subscription: "", fetchedAt: .distantPast)
        for (kind, reading) in [("session", live.fiveHour), ("weekly_all", live.sevenDay)] {
            guard let reading, reading.window.resetsAt > now else { continue }
            let existing = snap.bars.firstIndex { $0.kind == kind }
            if existing != nil, reading.receivedAt <= snap.fetchedAt { continue }
            let raw = Int(reading.window.usedPercentage.rounded())
            // The status line carries no severity; tint still turns orange at 90 % on percent alone.
            let bar = Bar(kind: kind, percent: max(0, min(100, raw)), rawPercent: raw, severity: raw >= 100 ? "exceeded" : "normal",
                          resetsAt: reading.window.resetsAt, modelName: nil)
            if let existing { snap.bars[existing] = bar } else { snap.bars.append(bar) }
            snap.liveAt = max(snap.liveAt ?? .distantPast, reading.receivedAt)
        }
        guard fetched != nil || snap.liveAt != nil else { return nil }
        snap.bars = snap.bars.enumerated()
            .sorted { ((kindOrder[$0.element.kind] ?? 99), $0.offset) < ((kindOrder[$1.element.kind] ?? 99), $1.offset) }
            .map(\.element)
        return snap
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    static func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }
}

/// The newest 5-hour and 7-day windows any Clinic session's status line has reported (ADR-162). The
/// windows are the account's, not the session's, so one value serves every session.
public struct LiveRateLimits: Sendable, Equatable {
    public struct Reading: Sendable, Equatable {
        public var window: StatusLineReport.RateWindow
        public var receivedAt: Date
    }
    public var fiveHour: Reading?
    public var sevenDay: Reading?

    public init() {}

    /// Folds in a report's windows; returns whether anything changed. A window the report leaves out is
    /// no news rather than cleared — the CLI omits one it has not heard about since launch, or whose reset
    /// has passed, and `UsageSnapshot.combining` already ignores a reading whose reset has passed. A window
    /// that repeats the one held keeps its first arrival time, so a burst of identical reports does not
    /// count as a newer reading than a fetch in between.
    @discardableResult
    public mutating func absorb(_ report: StatusLineReport, at: Date) -> Bool {
        var changed = false
        func take(_ window: StatusLineReport.RateWindow?, into reading: inout Reading?) {
            guard let window, reading?.window != window else { return }
            reading = Reading(window: window, receivedAt: at)
            changed = true
        }
        take(report.fiveHour, into: &fiveHour)
        take(report.sevenDay, into: &sevenDay)
        return changed
    }
}

public enum UsageError: Error, Equatable, CustomStringConvertible {
    case noCredentials, expired, malformed, http(Int, String)
    public var description: String {
        switch self {
        case .noCredentials: return "No Claude Code sign-in found. Run `claude` once to sign in."
        case .expired: return "Claude Code sign-in has expired. Run `claude` to refresh."
        case .malformed: return "Unexpected usage response."
        case .http(let code, let msg): return "HTTP \(code)" + (msg.isEmpty ? "" : ": \(msg)")
        }
    }
}

/// The CLI's OAuth credentials, read-only (ADR-018).
public struct ClaudeCredentials: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String) {
        self.accessToken = accessToken; self.expiresAt = expiresAt; self.subscriptionType = subscriptionType
    }

    /// Parses the JSON both the Keychain item and `~/.claude/.credentials.json` hold.
    public static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expires, subscriptionType: oauth["subscriptionType"] as? String ?? "")
    }

    public var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }
}

public enum UsageClient {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func fetch(credentials: ClaudeCredentials, session: URLSession = .shared) async throws -> UsageSnapshot {
        if credentials.isExpired { throw UsageError.expired }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("Clinic", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw UsageError.http(code, msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try UsageSnapshot.parse(data, subscription: credentials.subscriptionType)
    }
}
