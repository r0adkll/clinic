import Foundation

/// Vocabulary per ADR-025: Project, Session, Surface, Tab.

public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue.lowercased() }
    public static func generate() -> SessionID { SessionID(UUID().uuidString) }
    public var description: String { rawValue }
    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// Everything Clinic knows about a session from its transcript on disk (ADR-029).
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

    public init(id: SessionID, transcriptPath: String, cwd: String? = nil, lastCwd: String? = nil, gitBranch: String? = nil,
                firstPrompt: String? = nil, aiTitle: String? = nil, customTitle: String? = nil, model: String? = nil,
                totalCostUSD: Double? = nil, createdAt: Date? = nil, lastActivityAt: Date? = nil,
                fileSize: Int64 = 0, fileModifiedAt: Date = .distantPast) {
        self.id = id; self.transcriptPath = transcriptPath; self.cwd = cwd; self.lastCwd = lastCwd; self.gitBranch = gitBranch
        self.firstPrompt = firstPrompt; self.aiTitle = aiTitle; self.customTitle = customTitle; self.model = model
        self.totalCostUSD = totalCostUSD; self.createdAt = createdAt; self.lastActivityAt = lastActivityAt
        self.fileSize = fileSize; self.fileModifiedAt = fileModifiedAt
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
        return String(session.id.rawValue.prefix(8))
    }
}
