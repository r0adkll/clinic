import Foundation

/// A git object store and index that belong to Clinic rather than to the repository (ADR-080).
///
/// Everything git writes while these are in the environment lands in `objectDirectory`; the
/// repository's own objects are reached read-only through `GIT_ALTERNATE_OBJECT_DIRECTORIES`, so a
/// snapshot never adds an object, a ref or an index entry to the user's repo.
public struct GitObjectScratch: Sendable, Hashable {
    public var objectDirectory: String
    public var indexFile: String

    public init(objectDirectory: String, indexFile: String) {
        self.objectDirectory = objectDirectory
        self.indexFile = indexFile
    }

    /// The alternates path must be absolute — git silently fails to unpack a tree when it is not,
    /// which surfaces as `fatal: failed to unpack tree object HEAD`.
    public func environment(repoRoot: String) -> [String: String] {
        [
            "GIT_OBJECT_DIRECTORY": objectDirectory,
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": URL(fileURLWithPath: repoRoot).appendingPathComponent(".git/objects").standardizedFileURL.path,
            "GIT_INDEX_FILE": indexFile,
        ]
    }

    func prepare() throws {
        try FileManager.default.createDirectory(atPath: objectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (indexFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    }
}

/// One agent turn, bounded by the trees on disk when it started and when it stopped (ADR-080).
/// `headTree` is nil while the turn is in flight; the panel then diffs `baseTree` against a fresh
/// snapshot of the working tree instead.
public struct TurnSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var sessionId: SessionID
    public var repoRoot: String
    /// 1-based within the session.
    public var index: Int
    /// First line of the `UserPromptSubmit` prompt, trimmed; nil when the hook carried none.
    public var prompt: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var baseTree: String
    public var headTree: String?

    public init(sessionId: SessionID, repoRoot: String, index: Int, prompt: String? = nil,
                startedAt: Date, endedAt: Date? = nil, baseTree: String, headTree: String? = nil) {
        self.sessionId = sessionId
        self.repoRoot = repoRoot
        self.index = index
        self.prompt = prompt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.baseTree = baseTree
        self.headTree = headTree
    }

    public var id: String { "\(sessionId.rawValue)#\(index)" }
    public var isInFlight: Bool { headTree == nil }
    /// True when the turn ended having changed nothing on disk.
    public var isEmpty: Bool { headTree == baseTree }

    /// What the turn menu shows: the prompt's first line, else a positional fallback.
    public var label: String {
        guard let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return "Turn \(index)" }
        return p
    }
}

/// Every snapshot Clinic holds for one session in one repository. Persisted as JSON beside the
/// object store; a session that changes repository gets a second file under a different repo key,
/// which is what keeps unrelated trees from ever being diffed against each other.
public struct SessionSnapshots: Codable, Sendable, Equatable {
    public var sessionId: SessionID
    public var repoRoot: String
    /// The tree when this attach began (`SessionStart` with source `startup` or `resume`). Compact
    /// and clear restarts deliberately leave it alone, so "Session" means "since this attach".
    public var baselineTree: String?
    public var baselineAt: Date?
    public var turns: [TurnSnapshot]

    public init(sessionId: SessionID, repoRoot: String, baselineTree: String? = nil, baselineAt: Date? = nil, turns: [TurnSnapshot] = []) {
        self.sessionId = sessionId
        self.repoRoot = repoRoot
        self.baselineTree = baselineTree
        self.baselineAt = baselineAt
        self.turns = turns
    }

    public var openTurn: TurnSnapshot? { turns.last.flatMap { $0.isInFlight ? $0 : nil } }
    /// Newest first — the order the turn menu lists them in.
    public var recentTurns: [TurnSnapshot] { turns.reversed() }
}

/// What a hook event means for the turn history (ADR-080). Pure, so the mapping is a test rather
/// than something only a live session can exercise.
public enum SnapshotTrigger: Equatable, Sendable {
    /// `SessionStart` from `startup` or `resume`: the baseline the Session scope diffs from.
    case beginSession
    case beginTurn(prompt: String?)
    case endTurn

    public init?(event: HookEvent) {
        switch event.hookEventName {
        case "SessionStart":
            // A compact or clear restart is not a new attach and must not move the baseline; an
            // unlabelled SessionStart is treated as one, since `startup` is the common case.
            let source = event.source ?? "startup"
            guard source == "startup" || source == "resume" else { return nil }
            self = .beginSession
        case "UserPromptSubmit":
            self = .beginTurn(prompt: event.prompt)
        case "Stop", "StopFailure", "SessionEnd":
            self = .endTurn
        default:
            return nil
        }
    }
}
