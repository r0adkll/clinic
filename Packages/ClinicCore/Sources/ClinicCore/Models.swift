import Foundation

/// Vocabulary per ADR-025: Project, Session, Surface, Tab.

public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible, CodingKeyRepresentable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue.lowercased() }
    /// Lets `[SessionID: T]` encode as a JSON object instead of a flat key/value array.
    public var codingKey: CodingKey { StringKey(rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(codingKey.stringValue) }
    public static func generate() -> SessionID { SessionID(UUID().uuidString) }
    public var description: String { rawValue }
    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// Everything Clinic knows about a session from its transcript on disk (ADR-029).
struct StringKey: CodingKey {
    var stringValue: String; var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

public struct SessionSummary: Hashable, Codable, Sendable, Identifiable {
    public var id: SessionID
    public var transcriptPath: String
    /// The cwd recorded in the transcript (first record that has one). Project identity derives from this (ADR-030).
    public var cwd: String?
    /// Latest cwd seen in the tail (worktree hops).
    public var lastCwd: String?
    public var gitBranch: String?
    public var firstPrompt: String?
    public var aiTitle: String?
    public var customTitle: String?
    public var model: String?
    public var totalCostUSD: Double?
    public var createdAt: Date?
    public var lastActivityAt: Date?
    public var fileSize: Int64
    public var fileModifiedAt: Date
    /// Pull requests linked from the transcript (`pr-link` records) or mentioned in the first prompt, oldest first, unique by URL.
    public var pullRequests: [PullRequestRef] = []
    /// Absolute paths the agent wrote (Write/Edit/MultiEdit/NotebookEdit), newest last, de-duplicated, capped at 50.
    public var recentFiles: [String] = []

    public init(id: SessionID, transcriptPath: String, cwd: String? = nil, lastCwd: String? = nil, gitBranch: String? = nil,
                firstPrompt: String? = nil, aiTitle: String? = nil, customTitle: String? = nil, model: String? = nil,
                totalCostUSD: Double? = nil, createdAt: Date? = nil, lastActivityAt: Date? = nil,
                fileSize: Int64 = 0, fileModifiedAt: Date = .distantPast, pullRequests: [PullRequestRef] = []) {
        self.id = id; self.transcriptPath = transcriptPath; self.cwd = cwd; self.lastCwd = lastCwd; self.gitBranch = gitBranch
        self.firstPrompt = firstPrompt; self.aiTitle = aiTitle; self.customTitle = customTitle; self.model = model
        self.totalCostUSD = totalCostUSD; self.createdAt = createdAt; self.lastActivityAt = lastActivityAt
        self.fileSize = fileSize; self.fileModifiedAt = fileModifiedAt; self.pullRequests = pullRequests
    }

    /// Tolerant decoding: `pullRequests` was added after the scanner cache format shipped, so it may be absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SessionID.self, forKey: .id)
        transcriptPath = try c.decode(String.self, forKey: .transcriptPath)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        lastCwd = try c.decodeIfPresent(String.self, forKey: .lastCwd)
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        firstPrompt = try c.decodeIfPresent(String.self, forKey: .firstPrompt)
        aiTitle = try c.decodeIfPresent(String.self, forKey: .aiTitle)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        totalCostUSD = try c.decodeIfPresent(Double.self, forKey: .totalCostUSD)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        fileSize = try c.decode(Int64.self, forKey: .fileSize)
        fileModifiedAt = try c.decode(Date.self, forKey: .fileModifiedAt)
        pullRequests = try c.decodeIfPresent([PullRequestRef].self, forKey: .pullRequests) ?? []
        recentFiles = try c.decodeIfPresent([String].self, forKey: .recentFiles) ?? []
    }

    /// Best-effort "last activity" for ordering (ADR-040): last record timestamp, else file mtime.
    public var activityDate: Date { lastActivityAt ?? fileModifiedAt }
}

/// A directory group (ADR-030). Identity is the canonical absolute path.
public struct Project: Hashable, Codable, Sendable, Identifiable {
    public var path: String
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public init(path: String) { self.path = path }
}

public enum ProjectGrouping {
    /// Folds `<repo>/.claude/worktrees/<name>[/…]` into `<repo>` (ADR-030).
    public static func projectPath(forCwd cwd: String) -> String {
        let marker = "/.claude/worktrees/"
        if let range = cwd.range(of: marker) {
            return String(cwd[..<range.lowerBound])
        }
        return cwd
    }

    public static func project(for session: SessionSummary) -> Project? {
        guard let cwd = session.cwd ?? session.lastCwd else { return nil }
        return Project(path: projectPath(forCwd: cwd))
    }
}

public enum SessionNaming {
    /// ADR-031: manual > CLI custom title > CLI ai title > first prompt words.
    public static func displayName(for session: SessionSummary, manualName: String? = nil, maxWords: Int = 10) -> String {
        if let manualName, !manualName.trimmingCharacters(in: .whitespaces).isEmpty { return manualName }
        if let t = session.customTitle, !t.isEmpty { return t }
        if let t = session.aiTitle, !t.isEmpty { return t }
        if let p = session.firstPrompt {
            let words = p.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(maxWords)
            if !words.isEmpty { return words.joined(separator: " ") + (p.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count > maxWords ? "…" : "") }
        }
        return "New session"
    }
}

/// A pull request identified by its web URL (ADR-053). `repository` is `owner/name`; `host` is `github.com` or an enterprise host.
public struct PullRequestRef: Hashable, Codable, Sendable, Identifiable {
    public var number: Int
    public var repository: String
    public var url: URL
    public var host: String
    /// True when the ref was found in the session's first prompt rather than a `pr-link` transcript record.
    public var fromPrompt: Bool
    public var id: String { url.absoluteString }

    /// Parses `https://<host>/<owner>/<repo>/pull/<n>[/…]`. Any host is accepted (GitHub Enterprise); the path shape must match.
    public init?(url: URL, fromPrompt: Bool = false) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0,
              !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let owner = parts[0]
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !name.isEmpty, let canonical = URL(string: "https://\(host)/\(owner)/\(name)/pull/\(number)") else { return nil }
        self.init(number: number, repository: "\(owner)/\(name)", url: canonical, host: host, fromPrompt: fromPrompt)
    }

    public init(number: Int, repository: String, url: URL, fromPrompt: Bool = false) {
        self.init(number: number, repository: repository, url: url, host: url.host ?? "github.com", fromPrompt: fromPrompt)
    }

    public init(number: Int, repository: String, url: URL, host: String, fromPrompt: Bool) {
        self.number = number; self.repository = repository; self.url = url; self.host = host; self.fromPrompt = fromPrompt
    }

    /// Every PR URL in free text (`https://<host>/<owner>/<repo>/pull/<n>`), in order of appearance, unique by URL.
    public static func refs(in text: String, fromPrompt: Bool = false) -> [PullRequestRef] {
        guard let re = try? NSRegularExpression(pattern: #"https?://[A-Za-z0-9.\-]+(?::\d+)?/[^/\s<>()\[\]"']+/[^/\s<>()\[\]"']+/pull/\d+"#) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [PullRequestRef] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let u = URL(string: ns.substring(with: m.range)), let ref = PullRequestRef(url: u, fromPrompt: fromPrompt),
                  seen.insert(ref.id).inserted else { continue }
            out.append(ref)
        }
        return out
    }
}
