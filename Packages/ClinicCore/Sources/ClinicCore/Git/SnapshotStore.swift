import CryptoKit
import Foundation
import os

/// Records the working tree at every turn boundary so the diff panel can answer "what did this turn
/// change?" (ADR-080).
///
/// One actor for the whole app: a snapshot is a `git add -A` against a shared index file, so two of
/// them running at once on the same repository would corrupt it. Serialising across repositories as
/// well costs nothing — a snapshot is 20–45 ms — and removes a whole class of bug.
public actor SnapshotStore {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "snapshots")

    /// `…/Application Support/Clinic/snapshots`
    public let directory: URL
    /// A repo's snapshots are dropped once nothing has touched them for this long.
    public let retention: TimeInterval

    private var cache: [Key: SessionSnapshots] = [:]
    private let fm = FileManager.default

    private struct Key: Hashable { var repoKey: String; var sessionId: SessionID }

    public init(directory: URL = ClinicPaths.directory.appendingPathComponent("snapshots", isDirectory: true),
                retention: TimeInterval = 14 * 24 * 60 * 60) {
        self.directory = directory
        self.retention = retention
    }

    // MARK: Layout

    /// Repos are keyed by a hash of their root: the path itself is neither a legal directory name
    /// nor a stable one, and the hash keeps sessions in the same repo sharing one object store.
    static func repoKey(_ repoRoot: String) -> String {
        let normalized = URL(fileURLWithPath: repoRoot).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(20).description
    }

    private func repoDirectory(_ repoRoot: String) -> URL {
        directory.appendingPathComponent(Self.repoKey(repoRoot), isDirectory: true)
    }

    /// The object store and index for a repository. Callers hand this to `GitRepository`.
    public func scratch(for repoRoot: String) -> GitObjectScratch {
        let base = repoDirectory(repoRoot)
        return GitObjectScratch(objectDirectory: base.appendingPathComponent("objects").path,
                                indexFile: base.appendingPathComponent("index").path)
    }

    private func snapshotsURL(_ repoRoot: String, _ sessionId: SessionID) -> URL {
        repoDirectory(repoRoot).appendingPathComponent("turns", isDirectory: true)
            .appendingPathComponent("\(sessionId.rawValue).json")
    }

    // MARK: Reading

    public func snapshots(session: SessionID, repoRoot: String) -> SessionSnapshots {
        let key = Key(repoKey: Self.repoKey(repoRoot), sessionId: session)
        if let cached = cache[key] { return cached }
        let loaded = (try? Data(contentsOf: snapshotsURL(repoRoot, session)))
            .flatMap { try? Self.decoder.decode(SessionSnapshots.self, from: $0) }
            ?? SessionSnapshots(sessionId: session, repoRoot: repoRoot)
        cache[key] = loaded
        return loaded
    }

    private func save(_ snapshots: SessionSnapshots) {
        cache[Key(repoKey: Self.repoKey(snapshots.repoRoot), sessionId: snapshots.sessionId)] = snapshots
        let url = snapshotsURL(snapshots.repoRoot, snapshots.sessionId)
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(snapshots).write(to: url, options: .atomic)
        } catch {
            Self.log.error("saving turn snapshots: \(error, privacy: .public)")
        }
    }

    // MARK: Recording

    /// `SessionStart` with source `startup` or `resume`: the baseline the Session scope diffs from.
    /// A `compact` or `clear` restart must not call this — see ADR-080.
    @discardableResult
    public func beginSession(_ session: SessionID, repoRoot: String, at date: Date = Date()) async -> String? {
        guard let tree = await snapshot(repoRoot) else { return nil }
        var s = snapshots(session: session, repoRoot: repoRoot)
        s.baselineTree = tree
        s.baselineAt = date
        save(s)
        return tree
    }

    /// `UserPromptSubmit`: opens a turn at the tree as it is before the agent acts.
    @discardableResult
    public func beginTurn(_ session: SessionID, repoRoot: String, prompt: String?, at date: Date = Date()) async -> TurnSnapshot? {
        guard let tree = await snapshot(repoRoot) else { return nil }
        var s = snapshots(session: session, repoRoot: repoRoot)
        // A prompt arriving while a turn is open (an interrupt, or a Stop we never saw) closes the
        // old one where it stands rather than leaving it in flight forever.
        if s.openTurn != nil { s.turns[s.turns.count - 1].headTree = tree; s.turns[s.turns.count - 1].endedAt = date }
        if s.baselineTree == nil { s.baselineTree = tree; s.baselineAt = date }
        let turn = TurnSnapshot(sessionId: session, repoRoot: repoRoot, index: s.turns.count + 1,
                                prompt: Self.firstLine(prompt), startedAt: date, baseTree: tree)
        s.turns.append(turn)
        save(s)
        return turn
    }

    /// `Stop`, `StopFailure` or `SessionEnd`: closes the open turn. A no-op when none is open.
    @discardableResult
    public func endTurn(_ session: SessionID, repoRoot: String, at date: Date = Date()) async -> TurnSnapshot? {
        var s = snapshots(session: session, repoRoot: repoRoot)
        guard s.openTurn != nil, let tree = await snapshot(repoRoot) else { return nil }
        s.turns[s.turns.count - 1].headTree = tree
        s.turns[s.turns.count - 1].endedAt = date
        save(s)
        return s.turns.last
    }

    /// Applies whatever a hook event meant. The one entry point the app side needs.
    public func record(_ trigger: SnapshotTrigger, session: SessionID, repoRoot: String, at date: Date = Date()) async {
        switch trigger {
        case .beginSession: await beginSession(session, repoRoot: repoRoot, at: date)
        case .beginTurn(let prompt): await beginTurn(session, repoRoot: repoRoot, prompt: prompt, at: date)
        case .endTurn: await endTurn(session, repoRoot: repoRoot, at: date)
        }
    }

    private func snapshot(_ repoRoot: String) async -> String? {
        do {
            return try await GitRepository(root: repoRoot).writeSnapshotTree(scratch(for: repoRoot))
        } catch {
            Self.log.error("snapshot of \(repoRoot, privacy: .public) failed: \(error, privacy: .public)")
            return nil
        }
    }

    static func firstLine(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        let line = prompt.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line, !line.isEmpty else { return nil }
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    // MARK: Diffing

    /// The diff a turn produced: tree to tree once it has stopped, tree to live working tree while
    /// it is still running.
    public func diff(turn: TurnSnapshot) async throws -> UnifiedDiff {
        let repo = GitRepository(root: turn.repoRoot)
        let scratch = scratch(for: turn.repoRoot)
        if let head = turn.headTree {
            return try await repo.diff(from: turn.baseTree, to: head, scratch: scratch)
        }
        return try await repo.diff(from: turn.baseTree, toWorktree: scratch)
    }

    /// Everything this attach has changed: the session baseline against the live working tree.
    public func diffSinceSessionStart(_ session: SessionID, repoRoot: String) async throws -> UnifiedDiff? {
        guard let baseline = snapshots(session: session, repoRoot: repoRoot).baselineTree else { return nil }
        return try await GitRepository(root: repoRoot).diff(from: baseline, toWorktree: scratch(for: repoRoot))
    }

    // MARK: Retention

    /// Drops the snapshot directory of every repository not in `liveRepoRoots` whose files have not
    /// been touched within `retention`. Returns the roots' keys that were removed.
    @discardableResult
    public func prune(keeping liveRepoRoots: Set<String> = []) -> [String] {
        let live = Set(liveRepoRoots.map(Self.repoKey))
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var removed: [String] = []
        for entry in entries where !live.contains(entry.lastPathComponent) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, Date().timeIntervalSince(modified) > retention else { continue }
            do {
                try fm.removeItem(at: entry)
                removed.append(entry.lastPathComponent)
                cache = cache.filter { $0.key.repoKey != entry.lastPathComponent }
            } catch {
                Self.log.error("pruning \(entry.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            }
        }
        return removed
    }

    /// Bytes on disk, for Preferences → Diagnostics.
    public func diskUsage() -> Int64 {
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Deletes every snapshot Clinic holds. The next turn starts a fresh lineage.
    public func removeAll() {
        cache.removeAll()
        try? fm.removeItem(at: directory)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
