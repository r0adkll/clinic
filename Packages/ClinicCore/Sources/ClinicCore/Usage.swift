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

    static let kindOrder = ["session": 0, "weekly_all": 1, "weekly_scoped": 2]

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

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    static func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }
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
