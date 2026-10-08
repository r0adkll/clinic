import Foundation
import Observation
import os
import ClinicCore

/// Per-pane state for the diff panel (ADR-080). One diff reader; the scope chooses which pair of
/// trees it renders. Replaces `GitPageModel`, which framed the pane as a git client.
///
/// **One loader (ADR-183).** Everything that can make the panel stale — the file watcher, a turn
/// boundary, the reader choosing another scope or turn, the pane coming back to the front — asks for
/// a refresh through `request`, and one loop serves them one at a time. A scope resolves to a pair
/// of trees (`DiffTarget` → `DiffPair`), and the pair is the identity of what is on screen: the same
/// pair is not read or drawn again, and a result is applied only if the selection it was read for is
/// still the selection. The four entry points this replaced each ran their own load, in whatever
/// order git answered, and the slowest one won whatever the header said.
@MainActor
@Observable
final class DiffPanelModel {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "diff")

    /// Which context the panel is showing. The sub-selections live beside it rather than inside it,
    /// so switching away from a scope and back lands you where you were.
    enum Scope: String, CaseIterable, Identifiable {
        case turn, session, workingTree, branch
        var id: String { rawValue }
        var title: String {
            switch self {
            case .turn: "Turn"
            case .session: "Session"
            // What it holds, in the word the reader uses for it (ADR-187). The raw value stays: it is
            // what `-ClinicDiffScope` and the smoke scripts pass.
            case .workingTree: "Uncommitted"
            case .branch: "Branch"
            }
        }
        var symbol: String {
            switch self {
            case .turn: "bubble.left.and.text.bubble.right"
            case .session: "clock.arrow.circlepath"
            case .workingTree: "pencil.line"
            case .branch: "arrow.trianglehead.branch"
            }
        }
    }

    enum WorkingSide: String, CaseIterable, Identifiable {
        case all, unstaged, staged
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All changes"
            case .unstaged: "Unstaged"
            case .staged: "Staged"
            }
        }
        var side: DiffTarget.Side {
            switch self {
            case .all: .all
            case .unstaged: .unstaged
            case .staged: .staged
            }
        }
    }

    // MARK: Selection

    var scope: Scope = .turn { didSet { if scope != oldValue { selectionChanged() } } }
    /// nil means "the newest turn that changed something" (ADR-170), so a running session keeps
    /// following the live one and a question or a commit turn does not blank the panel.
    var selectedTurnId: String? { didSet { if selectedTurnId != oldValue { pendingTurnId = nil; selectionChanged() } } }
    var workingSide: WorkingSide = .all { didSet { if workingSide != oldValue { selectionChanged() } } }
    /// nil means "every commit on the branch", or on the default branch "the newest commit".
    var selectedCommit: String? { didSet { if selectedCommit != oldValue { selectionChanged() } } }
    /// A turn or session whose checkout moved shows only its own work unless the reader asks for
    /// everything the snapshots hold (ADR-185).
    var showsCheckoutMove = false { didSet { if showsCheckoutMove != oldValue { selectionChanged() } } }

    // MARK: Content

    private(set) var repo: GitRepository?
    private(set) var status: GitStatusSnapshot?
    private(set) var commits: [GitCommit] = []
    /// What the Branch scope diffs from; nil on the default branch, where there is nothing to diff
    /// the branch against and the scope shows the newest commit instead (ADR-170).
    private(set) var branchBase: String?
    /// Newest first, as the turn menu lists them.
    private(set) var turns: [TurnSnapshot] = []
    private(set) var files: [UnifiedDiffFile] = []
    /// The tree, the selection and the file on screen (ADR-101). The panel decides *which* diff;
    /// browsing it is the same job the pull request panel's Files tab does, so it is the same view.
    let browser = DiffBrowser()

    private(set) var isBound = false
    private(set) var error: String?
    /// `+n −n` per closed turn, numstat only, filled in whenever the turns are re-read.
    private(set) var turnStats: [String: DiffStat] = [:]
    /// The turn the Turn scope is showing when none is pinned (ADR-170).
    private(set) var followedTurnId: String?
    /// A newer turn has changes, and the panel has not moved to it because the reader is in the
    /// middle of the one on screen (ADR-187). Offered, not taken.
    private(set) var pendingTurnId: String?
    /// What is on screen, resolved: the two trees, and what moved under them.
    private(set) var resolution: DiffResolution?
    /// Other sessions that were changing this checkout during the turn on screen (ADR-185).
    private(set) var overlappingSessions = 0
    /// How much each scope holds right now, so the picker and the empty state can say where the
    /// changes are before the reader goes looking (ADR-188).
    private(set) var scopeStats: [Scope: DiffStat] = [:]

    private var sessionId: SessionID?
    private var snapshots: SnapshotService?
    private var watcher: FSEventsWatcher?
    private var watchTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    /// Bumped by every change of what the reader asked to see. A load reads it when it starts and
    /// checks it before it writes; one that no longer matches is dropped and the loop runs again.
    private var selectionEpoch = 0
    /// The epoch whose content is on screen.
    private var shownEpoch = -1
    private var shownPair: DiffPair?
    private var shownIdentity: String?
    private var bindGeneration = 0
    private var wants: Refresh = []
    private var draining = false
    /// Where `HEAD` stood at the last refresh. A commit, a checkout or a pull moves it, and that is
    /// when the commit list and the branch base have to be read again.
    private var lastHead: String?
    private var lastBranch: String?
    /// The checkout as the last completed refresh read it. The same tree under the same commit, with
    /// the same selection and the same turns, resolves to the same pairs: there is nothing to do.
    private var lastWorking: WorkingState?
    /// When this attach's baseline was taken, for saying what the Session scope starts from.
    private var baselineAt: Date?
    private var statsInFlight: Set<String> = []

    private struct Refresh: OptionSet {
        let rawValue: Int
        /// Status, commits, the branch base and the turn list.
        static let metadata = Refresh(rawValue: 1)
        static let diff = Refresh(rawValue: 2)
    }

    var hasRepo: Bool { repo != nil }
    /// A selection the reader made has not been shown yet. A refresh of what is already on screen
    /// is not loading: it replaces nothing until it has something to replace it with.
    var isLoading: Bool { shownEpoch != selectionEpoch }
    var totals: DiffStat {
        DiffStat(files: files.count,
                 additions: files.reduce(0) { $0 + $1.additions },
                 deletions: files.reduce(0) { $0 + $1.deletions })
    }

    /// The turn the panel is showing: the pinned selection, else the one "Latest changes" found.
    var selectedTurn: TurnSnapshot? {
        guard let id = selectedTurnId ?? followedTurnId else { return nil }
        return turns.first { $0.id == id }
    }

    var pendingTurn: TurnSnapshot? { pendingTurnId.flatMap { id in turns.first { $0.id == id } } }

    var selectedCommitSummary: GitCommit? {
        guard let sha = selectedCommit else { return nil }
        return commits.first { $0.sha == sha }
    }

    // MARK: Binding

    /// (Re)binds to the repository containing `directory`. Called each time the pane comes on screen,
    /// which is also what starts the watcher again: the side panel stops it whenever the pane is not
    /// the one showing, and a bind that found the same repository used to return before the only line
    /// that made one, so the panel stopped following the working tree after its first trip to the
    /// background (ADR-183).
    func bind(directory: String, sessionId: SessionID?, snapshots: SnapshotService?) async {
        bindGeneration += 1
        let generation = bindGeneration
        let found = await GitRepository.discover(from: directory)
        // A later bind started while this one was asking git; it has the newer answer.
        guard generation == bindGeneration else { return }
        defer { isBound = true }

        let sameRepo = found?.root == repo?.root
        let sameSession = sessionId == self.sessionId
        self.sessionId = sessionId
        self.snapshots = snapshots
        if !sameRepo {
            stopWatching()
            repo = found
            status = nil; commits = []; branchBase = nil; lastHead = nil; lastBranch = nil; lastWorking = nil
            scopeStats = [:]
        }
        if !sameRepo || !sameSession {
            turns = []; turnStats.removeAll(); followedTurnId = nil; pendingTurnId = nil; baselineAt = nil; lastWorking = nil
            files = []; resolution = nil; shownPair = nil; shownIdentity = nil; error = nil; overlappingSessions = 0
            browser.show([])
            selectionEpoch += 1
        }
        guard found != nil else { return }
        // Coming back to the pane is asking to see what is there now, not where the reader left off.
        browser.disengage()
        startWatching()
        request([.metadata, .diff])
    }

    private func startWatching() {
        guard watcher == nil, let root = repo?.root else { return }
        let watcher = FSEventsWatcher(paths: [root])
        self.watcher = watcher
        watcher.start()
        let stream = watcher.changes
        watchTask = Task { [weak self] in
            for await _ in stream { self?.scheduleRefresh() }
        }
    }

    func stopWatching() {
        watchTask?.cancel(); watchTask = nil
        debounce?.cancel(); debounce = nil
        watcher?.stop(); watcher = nil
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Every scope, not only those "headed by the working tree": resolving one whose trees did
            // not move costs a `rev-parse`, and deciding in advance which could have moved is what
            // left the Branch scope naming a new commit over the old commit's diff.
            self?.request(.diff)
        }
    }

    // MARK: Loading

    /// A turn boundary was recorded, or something else outside the repository changed.
    func reload() { request([.metadata, .diff]) }

    private func selectionChanged() {
        selectionEpoch += 1
        request(.diff)
    }

    /// Shows the newest turn with changes, which the panel held back from (ADR-187).
    func showPendingTurn() {
        pendingTurnId = nil
        followedTurnId = nil
        browser.disengage()
        if selectedTurnId != nil { selectedTurnId = nil } else { selectionChanged() }
    }

    private func request(_ what: Refresh) {
        wants.formUnion(what)
        guard !draining else { return }
        draining = true
        Task { [weak self] in await self?.drain() }
    }

    /// Serves refresh requests one at a time until none are left. Requests that arrive while one is
    /// running are folded together, so a burst of file events costs one more pass, not one each.
    private func drain() async {
        while !wants.isEmpty, let repo, let store = snapshots?.store {
            var now = wants
            wants = []
            let epoch = selectionEpoch
            do {
                let working = try await store.workingState(repoRoot: repo.root)
                if working.commit != lastHead || working.branch != lastBranch || status == nil {
                    lastHead = working.commit
                    lastBranch = working.branch
                    now.insert(.metadata)
                }
                // A build writing ignored files fires the watcher constantly and changes nothing git
                // would care about. Staged and Unstaged are the exception: `git add` moves the index
                // and neither the tree nor `HEAD`.
                let readsIndex = scope == .workingTree && workingSide != .all
                if working == lastWorking, shownEpoch == epoch, !now.contains(.metadata), !readsIndex, error == nil { continue }
                if now.contains(.metadata) { await loadMetadata(repo) }
                guard epoch == selectionEpoch, repo.root == self.repo?.root else { wants.insert(.diff); continue }
                try await loadDiff(repo, store: store, working: working, epoch: epoch)
                if epoch == selectionEpoch { lastWorking = working }
            } catch {
                // What is on screen stays if it is still what was asked for; a failed refresh is a
                // banner over it, not an empty panel. A failed *selection* has nothing to keep.
                if epoch == selectionEpoch {
                    if shownEpoch != epoch { files = []; resolution = nil; shownPair = nil; shownIdentity = nil; browser.show([]) }
                    shownEpoch = epoch
                    self.error = "\(error)"
                }
                Self.log.error("diff panel load (\(self.scope.rawValue, privacy: .public)): \(error, privacy: .public)")
            }
        }
        wants = []
        draining = false
    }

    private func loadMetadata(_ repo: GitRepository) async {
        do {
            status = try await repo.status()
            commits = try await repo.commits(limit: 100)
            branchBase = await repo.branchBaseRef()
        } catch {
            Self.log.error("diff panel metadata: \(error, privacy: .public)")
        }
        guard let sessionId, let snapshots, repo.root == self.repo?.root else { return }
        let recorded = await snapshots.snapshots(for: sessionId, repoRoot: repo.root)
        turns = recorded.recentTurns
        baselineAt = recorded.baselineAt
        // A turn pinned by id that no longer exists (snapshots cleared) falls back to the newest.
        if let id = selectedTurnId, !turns.contains(where: { $0.id == id }) { selectedTurnId = nil }
        if let id = followedTurnId, !turns.contains(where: { $0.id == id }) { followedTurnId = nil }
        if let id = pendingTurnId, !turns.contains(where: { $0.id == id }) { pendingTurnId = nil }
        loadTurnStats(repo)
    }

    /// One scope, resolved: the trees, and — for the Turn scope — which turn they belong to.
    private struct Selection {
        var resolution: DiffResolution
        var turn: TurnSnapshot?
        var pending: String?
        /// Which diff this is, as opposed to what is in it: a turn, a commit, a branch. The same
        /// thing with moved trees is a refresh; a different thing is a different diff, even when the
        /// reader did not ask for it — the newest commit after a commit lands, the next turn.
        var identity: String
    }

    /// The one place a scope becomes a pair of trees. `active` is the scope on screen, for which
    /// following holds still (ADR-187); the others are only being counted.
    private func selection(for scope: Scope, store: SnapshotStore, root: String, working: WorkingState, active: Bool) async throws -> Selection? {
        switch scope {
        case .turn:
            if let id = selectedTurnId {
                guard let turn = turns.first(where: { $0.id == id }),
                      let resolved = try await store.resolve(.turn(turn), repoRoot: root, working: working) else { return nil }
                return Selection(resolution: resolved, turn: turn, identity: "turn:\(turn.id)")
            }
            // Newest first. A closed turn whose trees match is skipped without running git, so this
            // costs one resolve unless the live turn has not changed anything yet.
            var newest: Selection?
            for turn in turns where turn.isInFlight || !turn.isEmpty {
                guard let resolved = try await store.resolve(.turn(turn), repoRoot: root, working: working) else { continue }
                // A turn that only moved the checkout has no work of its own to follow.
                if !resolved.pair.isEmpty { newest = Selection(resolution: resolved, turn: turn, identity: "turn:\(turn.id)"); break }
            }
            // Hold still: the reader is in the middle of the turn on screen, and a newer one having
            // changes is news to offer, not a reason to swap the file under them.
            if active, let newest, let shown = followedTurnId, newest.turn?.id != shown, browser.isEngaged,
               let current = turns.first(where: { $0.id == shown }),
               let resolved = try await store.resolve(.turn(current), repoRoot: root, working: working), !resolved.pair.isEmpty {
                return Selection(resolution: resolved, turn: current, pending: newest.turn?.id, identity: "turn:\(current.id)")
            }
            return newest
        case .session:
            guard let sessionId, let resolved = try await store.resolve(.session(sessionId), repoRoot: root, working: working) else { return nil }
            return Selection(resolution: resolved, identity: "session")
        case .workingTree:
            let side = active ? workingSide.side : .all
            return try await store.resolve(.uncommitted(side), repoRoot: root, working: working)
                .map { Selection(resolution: $0, identity: "uncommitted:\(side.rawValue)") }
        case .branch:
            if active, let sha = selectedCommit {
                return try await store.resolve(.commit(sha), repoRoot: root, working: working)
                    .map { Selection(resolution: $0, identity: "commit:\(sha)") }
            }
            // On the default branch "the branch against its base" is always empty; the newest commit
            // is what a reader there wants, and is what a trunk-based repo's last turn committed.
            guard let base = branchBase else {
                guard let newest = commits.first else { return nil }
                return try await store.resolve(.commit(newest.sha), repoRoot: root, working: working)
                    .map { Selection(resolution: $0, identity: "commit:\(newest.sha)") }
            }
            return try await store.resolve(.branch(base: base), repoRoot: root, working: working)
                .map { Selection(resolution: $0, identity: "branch:\(base)") }
        }
    }

    private func loadDiff(_ repo: GitRepository, store: SnapshotStore, working: WorkingState, epoch: Int) async throws {
        let root = repo.root
        let scope = self.scope
        let chosen = try await selection(for: scope, store: store, root: root, working: working, active: true)
        guard epoch == selectionEpoch else { wants.insert(.diff); return }

        let pair = chosen.map { showsCheckoutMove ? ($0.resolution.whole ?? $0.resolution.pair) : $0.resolution.pair }
        // A fresh diff is one the reader asked for, or one the panel moved to; the same selection
        // refreshing is not, and may not move the reader's file or line (ADR-186, ADR-187).
        let fresh = shownEpoch != epoch || chosen?.identity != shownIdentity

        if pair != shownPair || shownEpoch != epoch {
            var loaded: [UnifiedDiffFile] = []
            if let pair { loaded = try await store.diff(pair).files }
            guard epoch == selectionEpoch else { wants.insert(.diff); return }
            files = loaded
            shownPair = pair
            shownIdentity = chosen?.identity
            browser.show(loaded, source: pair.map { Self.source(for: $0, store: store) }, fresh: fresh)
        }
        resolution = chosen?.resolution
        if scope == .turn {
            if selectedTurnId == nil { followedTurnId = chosen?.turn?.id }
            pendingTurnId = chosen?.pending
        }
        shownEpoch = epoch
        error = nil

        var overlap = 0
        if scope == .turn, let turn = chosen?.turn { overlap = await store.sessionsOverlapping(turn) }
        if overlap != overlappingSessions { overlappingSessions = overlap }
        await loadScopeStats(store: store, root: root, working: working, epoch: epoch)
    }

    /// Reads the files of one pair whole: each side's text for highlighting, and the diff with the
    /// whole file as its context.
    private static func source(for pair: DiffPair, store: SnapshotStore) -> DiffContentSource {
        DiffContentSource(
            text: { file, side in
                switch side {
                case .new: await store.text(of: file.newPath ?? file.path, in: pair.head, repoRoot: pair.repoRoot)
                case .old: await store.text(of: file.oldPath ?? file.path, in: pair.base, repoRoot: pair.repoRoot)
                }
            },
            whole: { file in try? await store.file(file, of: pair, context: 100_000) })
    }

    /// How much each scope holds. The one on screen is counted from what is on screen; the others
    /// are numstat only, cached by tree pair, so an idle refresh costs nothing here.
    private func loadScopeStats(store: SnapshotStore, root: String, working: WorkingState, epoch: Int) async {
        var counted: [Scope: DiffStat] = [:]
        for candidate in Scope.allCases {
            if candidate == scope {
                counted[candidate] = totals
            } else if let other = try? await selection(for: candidate, store: store, root: root, working: working, active: false) {
                counted[candidate] = await store.stat(other.resolution.pair)
            }
            guard epoch == selectionEpoch else { return }
        }
        if counted != scopeStats { scopeStats = counted }
    }

    /// `-ClinicDiffSelectFile <path>`: what a click in the tree does, for a smoke run that cannot
    /// synthesise one.
    func smokeSelect(path: String) {
        browser.select(path)
        Self.log.info("smokeSelect: \(path, privacy: .public) of \(self.files.count, privacy: .public) files")
    }

    /// Fills `turnStats` for closed turns not yet counted. Numstat only, never a patch; a turn whose
    /// trees match needs no git at all, and a closed turn's total never changes, so each is read once.
    /// Counted from the turn's own work, so a turn that switched branch shows what it wrote and not
    /// what the switch brought (ADR-185).
    private func loadTurnStats(_ repo: GitRepository) {
        guard let store = snapshots?.store else { return }
        let root = repo.root
        let missing = turns.filter { turnStats[$0.id] == nil && !statsInFlight.contains($0.id) && !$0.isInFlight && !$0.isEmpty }
        guard !missing.isEmpty else { return }
        statsInFlight.formUnion(missing.map(\.id))
        Task { [weak self] in
            for turn in missing {
                let resolved = try? await store.resolve(.turn(turn), repoRoot: root)
                let stat: DiffStat? = if let resolved { await store.stat(resolved.pair) } else { nil }
                self?.statsInFlight.remove(turn.id)
                if let stat { self?.turnStats[turn.id] = stat }
            }
        }
    }

    // MARK: What is being compared (ADR-187)

    /// One line naming both sides of the diff on screen: the thing a header that says only "Turn"
    /// or "Branch" leaves the reader to work out.
    var comparison: String? {
        guard let resolution else { return nil }
        let head = resolution.headIsLive ? "now" : nil
        switch scope {
        case .turn:
            guard let turn = selectedTurn else { return nil }
            let end = turn.endedAt.map(Self.clock) ?? "now, still running"
            return "Turn #\(turn.index) · \(Self.clock(turn.startedAt)) → \(end)"
        case .session:
            return "Since this session attached\(baselineAt.map { " at \(Self.clock($0))" } ?? "") → \(head ?? "now")"
        case .workingTree:
            let commit = resolution.baseCommit.map(Self.short) ?? "nothing committed"
            let branch = status?.branch.map { "\($0) " } ?? ""
            switch workingSide {
            case .all: return "\(branch)\(commit) → working tree"
            case .staged: return "\(branch)\(commit) → staged"
            case .unstaged: return "Staged → working tree"
            }
        case .branch:
            if let head = resolution.headCommit, let base = resolution.baseCommit, let name = branchBase {
                return "Where it left \(name) (\(Self.short(base))) → \(Self.short(head))"
            }
            guard let head = resolution.headCommit else { return nil }
            return "Commit \(Self.short(head)) against the commit before it"
        }
    }

    private static func short(_ sha: String) -> String { String(sha.prefix(7)) }

    private static func clock(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
                                             : date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Empty states

    /// Why the current scope is showing nothing, when it is showing nothing.
    var emptyReason: String? {
        guard !isLoading, files.isEmpty, error == nil else { return nil }
        switch scope {
        case .turn:
            if sessionId == nil { return "Only sessions Clinic started record turns." }
            if turns.isEmpty { return "No turns recorded yet. The next prompt in this session starts one." }
            if selectedTurnId == nil { return "No turn in this session has changed a file yet." }
            return resolution?.move != nil && !showsCheckoutMove ? "This turn moved the checkout and wrote nothing of its own."
                                                                  : "This turn changed nothing on disk."
        case .session:
            return sessionId == nil ? "Only sessions Clinic started record turns." : "Nothing has changed since this session started."
        case .workingTree:
            return workingSide == .staged ? "Nothing is staged." : workingSide == .unstaged ? "Nothing is unstaged." : "Everything is committed."
        case .branch:
            if selectedCommit == nil, branchBase == nil, commits.isEmpty { return "This branch has no commits yet." }
            return selectedCommit == nil && branchBase != nil ? "This branch matches its base." : "This commit changed nothing."
        }
    }

    /// The other scopes that do hold changes, for an empty state that says where to look.
    var scopesWithChanges: [(scope: Scope, stat: DiffStat)] {
        Scope.allCases.compactMap { candidate in
            guard candidate != scope, let stat = scopeStats[candidate], !stat.isEmpty else { return nil }
            return (candidate, stat)
        }
    }
}
