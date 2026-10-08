import Foundation
import os

/// What the diff panel is asked to show (ADR-183). Every case comes down to two trees, and the panel
/// knows nothing about how: a turn's snapshots, the index, a commit and a branch are all resolved
/// here, in one place, to a `DiffPair`.
public enum DiffTarget: Sendable, Hashable {
    /// One turn: its base tree against its head, or against the working tree while it runs.
    case turn(TurnSnapshot)
    /// Everything since this attach: the session baseline against the working tree.
    case session(SessionID)
    /// What has not been committed.
    case uncommitted(Side)
    /// Everything the current branch added since it left `base`.
    case branch(base: String)
    /// One commit against its first parent.
    case commit(String)

    public enum Side: String, Sendable, CaseIterable {
        /// `HEAD` against the working tree, untracked files included.
        case all
        /// The index against the working tree.
        case unstaged
        /// `HEAD` against the index.
        case staged
    }
}

/// Two trees in one repository. This is the identity of a diff: the same pair is the same diff, so
/// a pair that has not changed needs no git and no redraw (ADR-183).
public struct DiffPair: Sendable, Hashable {
    public var repoRoot: String
    public var base: String
    public var head: String

    public init(repoRoot: String, base: String, head: String) {
        self.repoRoot = repoRoot
        self.base = base
        self.head = head
    }

    /// Identical trees differ in nothing, and trees that differ in anything are not identical, so
    /// this answers "is there a diff" without running one.
    public var isEmpty: Bool { base == head }
}

/// The checkout itself moved while a turn or a session ran (ADR-185): a branch switch, a pull, a
/// rebase onto newer history. Everything that move brought is in the tree pair, and none of it is
/// the turn's work.
public struct CheckoutMove: Sendable, Hashable {
    public var fromCommit: String
    /// The commit that already existed before the turn and that `HEAD` now stands on.
    public var toCommit: String
    public var fromBranch: String?
    public var toBranch: String?

    public init(fromCommit: String, toCommit: String, fromBranch: String? = nil, toBranch: String? = nil) {
        self.fromCommit = fromCommit
        self.toCommit = toCommit
        self.fromBranch = fromBranch
        self.toBranch = toBranch
    }

    public var changedBranch: Bool { fromBranch != toBranch }
}

/// A target, resolved: the pair to show and what the reader should be told about it.
public struct DiffResolution: Sendable, Hashable {
    /// What the target changed. When the checkout moved, this is the target's own work: the move is
    /// taken out of it.
    public var pair: DiffPair
    /// Everything between the two snapshots, when that is more than `pair`.
    public var whole: DiffPair?
    public var move: CheckoutMove?
    /// The commits either side stood on, for saying what is being compared. nil where there is none.
    public var baseCommit: String?
    public var headCommit: String?
    /// The head is the working tree as it is now, so it will move.
    public var headIsLive: Bool

    public init(pair: DiffPair, whole: DiffPair? = nil, move: CheckoutMove? = nil,
                baseCommit: String? = nil, headCommit: String? = nil, headIsLive: Bool = false) {
        self.pair = pair
        self.whole = whole
        self.move = move
        self.baseCommit = baseCommit
        self.headCommit = headCommit
        self.headIsLive = headIsLive
    }
}

/// The checkout as it is right now: a tree of the working tree, and where `HEAD` stands. Read once
/// per refresh and handed to every `resolve` in it, so counting four scopes costs one snapshot.
public struct WorkingState: Sendable, Hashable {
    public var tree: String
    public var commit: String?
    public var branch: String?

    public init(tree: String, commit: String? = nil, branch: String? = nil) {
        self.tree = tree
        self.commit = commit
        self.branch = branch
    }
}

extension SnapshotStore {
    private static let targetLog = Logger(subsystem: "com.r0adkll.clinic", category: "diff")

    public func workingState(repoRoot: String) async throws -> WorkingState {
        let tree = try await liveTree(repoRoot: repoRoot)
        let head = await GitRepository(root: repoRoot).headState()
        return WorkingState(tree: tree, commit: head.commit, branch: head.branch)
    }

    /// Turns a target into the two trees it compares (ADR-183). nil when the target has nothing to
    /// compare from: a session with no baseline, a branch with no merge base.
    ///
    /// `working` is the checkout as the caller has already read it. A refresh resolves several
    /// targets — the one on screen and the others it counts — and one snapshot serves them all.
    public func resolve(_ target: DiffTarget, repoRoot: String, working: WorkingState? = nil) async throws -> DiffResolution? {
        let repo = GitRepository(root: repoRoot)
        var known = working
        func now() async throws -> WorkingState {
            if let known { return known }
            let read = try await workingState(repoRoot: repoRoot)
            known = read
            return read
        }

        switch target {
        case .turn(let turn):
            if let head = turn.headTree {
                return await ownWork(repo, base: turn.baseTree, baseCommit: turn.baseCommit, baseBranch: turn.baseBranch,
                                     since: turn.startedAt, head: head, headCommit: turn.headCommit,
                                     headBranch: turn.headBranch, headIsLive: false)
            }
            let state = try await now()
            return await ownWork(repo, base: turn.baseTree, baseCommit: turn.baseCommit, baseBranch: turn.baseBranch,
                                 since: turn.startedAt, head: state.tree, headCommit: state.commit, headBranch: state.branch,
                                 headIsLive: true)

        case .session(let session):
            let recorded = snapshots(session: session, repoRoot: repoRoot)
            guard let baseline = recorded.baselineTree else { return nil }
            let state = try await now()
            return await ownWork(repo, base: baseline, baseCommit: recorded.baselineCommit, baseBranch: recorded.baselineBranch,
                                 since: recorded.baselineAt ?? .distantPast, head: state.tree, headCommit: state.commit,
                                 headBranch: state.branch, headIsLive: true)

        case .uncommitted(let side):
            let head = working != nil ? working?.commit : await repo.headState().commit
            let committed = head == nil ? try await repo.emptyTree() : try await repo.tree(of: "HEAD")
            let scratch = scratch(for: repoRoot)
            switch side {
            case .all:
                return DiffResolution(pair: DiffPair(repoRoot: repoRoot, base: committed, head: try await now().tree),
                                      baseCommit: head, headIsLive: true)
            case .staged:
                let index = try await exclusive { try await repo.indexTree(scratch) }
                return DiffResolution(pair: DiffPair(repoRoot: repoRoot, base: committed, head: index), baseCommit: head)
            case .unstaged:
                let index = try await exclusive { try await repo.indexTree(scratch) }
                return DiffResolution(pair: DiffPair(repoRoot: repoRoot, base: index, head: try await now().tree), headIsLive: true)
            }

        case .branch(let base):
            let current = working != nil ? working?.commit : await repo.headState().commit
            guard let head = current, let fork = await repo.mergeBase(base, head) else { return nil }
            return DiffResolution(pair: DiffPair(repoRoot: repoRoot, base: try await repo.tree(of: fork), head: try await repo.tree(of: head)),
                                  baseCommit: fork, headCommit: head)

        case .commit(let sha):
            return DiffResolution(pair: DiffPair(repoRoot: repoRoot, base: try await repo.parentTree(of: sha), head: try await repo.tree(of: sha)),
                                  headCommit: sha)
        }
    }

    /// Narrows a snapshot pair to what was done between them, when the checkout moved in between
    /// (ADR-185).
    ///
    /// The checkout has moved when `HEAD` now stands on history that already existed before `since`
    /// and is not where it started. Commits made since are the work itself and move nothing: a turn
    /// that commits what it wrote leaves the tree as it was. Staying on one branch and landing on an
    /// *ancestor* of the start is a rewind — a reset, an amend — which is also the turn's own doing.
    ///
    /// When it has moved, the base becomes the tree the work would have started from had the checkout
    /// already been there: the landed-on commit, with whatever was uncommitted at the start carried
    /// across. Failing any step leaves the whole pair, which is what the panel showed before.
    private func ownWork(_ repo: GitRepository, base: String, baseCommit: String?, baseBranch: String?, since: Date,
                         head: String, headCommit: String?, headBranch: String?, headIsLive: Bool) async -> DiffResolution {
        let whole = DiffPair(repoRoot: repo.root, base: base, head: head)
        var resolution = DiffResolution(pair: whole, baseCommit: baseCommit, headCommit: headCommit, headIsLive: headIsLive)
        guard !whole.isEmpty, let baseCommit, let headCommit, baseCommit != headCommit,
              let landed = await repo.newestCommit(reachableFrom: headCommit, before: since), landed != baseCommit else { return resolution }
        if baseBranch == headBranch, await repo.isAncestor(landed, of: baseCommit) { return resolution }

        let key = CarryKey(repoRoot: repo.root, onto: landed, dirty: base, clean: baseCommit)
        do {
            let carried: String
            if let known = carriedTrees[key] {
                carried = known
            } else {
                let scratch = scratch(for: repo.root)
                let clean = try await repo.tree(of: baseCommit)
                let onto = try await repo.tree(of: landed)
                carried = try await exclusive { try await repo.tree(onto, carrying: base, over: clean, scratch: scratch) }
                carriedTrees[key] = carried
            }
            resolution.pair = DiffPair(repoRoot: repo.root, base: carried, head: head)
            resolution.whole = whole
            resolution.move = CheckoutMove(fromCommit: baseCommit, toCommit: landed, fromBranch: baseBranch, toBranch: headBranch)
        } catch {
            Self.targetLog.error("carrying a turn across a checkout move: \(error, privacy: .public)")
        }
        return resolution
    }

    // MARK: Reading a pair

    /// The diff between a pair's trees. The last few are kept, so going back to a turn or a scope
    /// that was just on screen is immediate.
    public func diff(_ pair: DiffPair) async throws -> UnifiedDiff {
        guard !pair.isEmpty else { return UnifiedDiff() }
        if let index = recentDiffs.firstIndex(where: { $0.pair == pair }) {
            let hit = recentDiffs.remove(at: index)
            recentDiffs.append(hit)
            return hit.diff
        }
        let diff = try await GitRepository(root: pair.repoRoot).diff(from: pair.base, to: pair.head, scratch: scratch(for: pair.repoRoot))
        recentDiffs.append((pair, diff))
        if recentDiffs.count > 8 { recentDiffs.removeFirst() }
        return diff
    }

    /// One file of a pair with `context` lines around each change — in practice the whole file, which
    /// is how the reader asks to see a change in its surroundings (ADR-188).
    public func file(_ file: UnifiedDiffFile, of pair: DiffPair, context: Int) async throws -> UnifiedDiffFile? {
        let paths = [file.oldPath, file.newPath].compactMap { $0 }
        let diff = try await GitRepository(root: pair.repoRoot).diff(from: pair.base, to: pair.head, scratch: scratch(for: pair.repoRoot),
                                                                    context: context, paths: Array(Set(paths)))
        return diff.files.first { $0.path == file.path } ?? diff.files.first
    }

    /// `+n −n` for a pair, read once: a tree pair's totals never change.
    public func stat(_ pair: DiffPair) async -> DiffStat {
        guard !pair.isEmpty else { return DiffStat() }
        if let known = stats[pair] { return known }
        let repo = GitRepository(root: pair.repoRoot)
        guard let stat = try? await repo.stat(from: pair.base, to: pair.head, scratch: scratch(for: pair.repoRoot)) else { return DiffStat() }
        if stats.count > 4_000 { stats.removeAll() }
        stats[pair] = stat
        return stat
    }

    /// A file's text as it stands in one of a pair's trees, for highlighting it whole (ADR-186).
    public func text(of path: String, in tree: String, repoRoot: String) async -> String? {
        await GitRepository(root: repoRoot).text(of: path, in: tree, scratch: scratch(for: repoRoot))
    }

    /// A file's bytes as they stand in one of a pair's trees, for showing an image on each side (ADR-189).
    public func data(of path: String, in tree: String, repoRoot: String) async -> Data? {
        await GitRepository(root: repoRoot).data(of: path, in: tree, scratch: scratch(for: repoRoot))
    }

    // MARK: Other sessions

    /// How many other sessions were changing this checkout while `turn` ran (ADR-185). A turn is two
    /// snapshots of one working tree, so whatever another session wrote in between is in its diff, and
    /// nothing in the trees can say whose it was. Their own recorded turns can say it happened.
    public func sessionsOverlapping(_ turn: TurnSnapshot, now: Date = Date()) -> Int {
        let directory = turnsDirectory(turn.repoRoot)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        let window = turn.startedAt...(max(turn.endedAt ?? now, turn.startedAt))
        var count = 0
        for file in files where file.hasSuffix(".json") {
            let session = SessionID(String(file.dropLast(".json".count)))
            guard session != turn.sessionId else { continue }
            let theirs = snapshots(session: session, repoRoot: turn.repoRoot).turns
            let overlapped = theirs.contains { other in
                guard other.isInFlight || !other.isEmpty else { return false }
                // An open turn with no end is running now, or was abandoned. Past a few hours it is
                // the second, and it would otherwise overlap every turn recorded after it.
                guard let end = other.endedAt ?? (now.timeIntervalSince(other.startedAt) < 6 * 3600 ? now : nil) else { return false }
                return other.startedAt <= window.upperBound && end >= window.lowerBound
            }
            if overlapped { count += 1 }
        }
        return count
    }
}
