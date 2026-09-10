import Foundation
import Observation
import os
import ClinicCore

/// Per-pane state for the diff panel (ADR-080). One diff reader; the scope chooses which pair of
/// trees it renders. Replaces `GitPageModel`, which framed the pane as a git client.
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
            case .workingTree: "Working tree"
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
    }

    // MARK: Selection

    var scope: Scope = .turn { didSet { if scope != oldValue { reloadDiff() } } }
    /// nil means "the newest turn", so a running session keeps following the live one.
    var selectedTurnId: String? { didSet { if selectedTurnId != oldValue { reloadDiff() } } }
    var workingSide: WorkingSide = .all { didSet { if workingSide != oldValue { reloadDiff() } } }
    /// nil means "every commit on the branch".
    var selectedCommit: String? { didSet { if selectedCommit != oldValue { reloadDiff() } } }

    // MARK: Content

    private(set) var repo: GitRepository?
    private(set) var status: GitStatusSnapshot?
    private(set) var commits: [GitCommit] = []
    /// Newest first, as the turn menu lists them.
    private(set) var turns: [TurnSnapshot] = []
    private(set) var files: [UnifiedDiffFile] = []
    /// Chip-sized descriptions for the rail, rebuilt only when the diff itself changes.
    private(set) var fileSummaries: [DiffFileSummary] = []
    /// The paged, flattened rows. The body renders `text` — the same page as one text document
    /// (ADR-100) — but paging, collapsing and highlighting are all still stated in rows.
    private(set) var page = DiffPage()
    /// What the body renders, by reference: the document plus whatever highlighting has arrived.
    let text = DiffTextSource()
    /// Files the reader has collapsed by hand. Collapsing frees a file's whole line budget, so it
    /// is also the way out of a diff too large to page through comfortably.
    private(set) var collapsed: Set<String> = []
    /// How many files the page renders. It grows only when the reader asks — collapsing a file
    /// makes the page cheaper, it does not pull unrelated files onto the screen.
    private(set) var pagedFileCount = 0

    /// Rows, not files. Building them is cheap (72k rows in ~26 ms) — the cost that matters is
    /// highlighting, which runs off the main actor after the text is already on screen.
    static let lineBudget = 20_000
    private(set) var isLoading = false
    private(set) var isBound = false
    private(set) var error: String?
    /// `+n −n` for a turn, filled in lazily when the menu asks (a patch per turn would be wasteful).
    private(set) var turnStats: [String: DiffStat] = [:]

    private let highlighter = DiffSyntaxHighlighter()
    private let rowCache = DiffPage.RowCache()
    private var highlightTask: Task<Void, Never>?
    /// Files whose highlighting has already landed. Row ids are stable for the life of a diff, so
    /// collapsing or paging never invalidates what is already coloured.
    private var highlightedFiles: Set<String> = []
    private var sessionId: SessionID?
    private var snapshots: SnapshotService?
    private var watcher: FSEventsWatcher?
    private var watchTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    var hasRepo: Bool { repo != nil }
    var totals: DiffStat {
        DiffStat(files: files.count,
                 additions: files.reduce(0) { $0 + $1.additions },
                 deletions: files.reduce(0) { $0 + $1.deletions })
    }

    /// The turn the panel is showing: the pinned selection, else the newest.
    var selectedTurn: TurnSnapshot? {
        if let id = selectedTurnId { return turns.first { $0.id == id } }
        return turns.first
    }

    var selectedCommitSummary: GitCommit? {
        guard let sha = selectedCommit else { return nil }
        return commits.first { $0.sha == sha }
    }

    /// True when the scope's head is the working tree, so a file-system change can move it.
    private var followsWorktree: Bool {
        switch scope {
        case .session, .workingTree: true
        case .turn: selectedTurn?.isInFlight ?? false
        case .branch: false
        }
    }

    // MARK: Binding

    /// (Re)binds to the repository containing `directory`. Cheap when the root is unchanged.
    func bind(directory: String, sessionId: SessionID?, snapshots: SnapshotService?) async {
        self.sessionId = sessionId
        self.snapshots = snapshots
        let found = await GitRepository.discover(from: directory)
        defer { isBound = true }
        if let found, let current = repo, current.root == found.root {
            await reload()
            return
        }
        stopWatching()
        repo = found
        status = nil; commits = []; turns = []; files = []; error = nil
        turnStats.removeAll()
        guard let found else { return }
        let root = found.root
        watcher = FSEventsWatcher(paths: [root])
        watcher?.start()
        if let stream = watcher?.changes {
            watchTask = Task { [weak self] in
                for await _ in stream { self?.scheduleReload() }
            }
        }
        await reload()
    }

    func stopWatching() {
        watchTask?.cancel(); watchTask = nil
        watcher?.stop(); watcher = nil
    }

    private func scheduleReload() {
        // A commit or a finished turn cannot move under us; only re-read what the change can affect.
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reload(diff: self?.followsWorktree ?? true)
        }
    }

    // MARK: Loading

    func reload(diff shouldReloadDiff: Bool = true) async {
        guard let repo else { return }
        let root = repo.root
        do {
            status = try await repo.status()
            commits = try await repo.commits(limit: 100)
            error = nil
        } catch {
            self.error = "\(error)"
            Self.log.error("diff panel reload: \(error, privacy: .public)")
        }
        if let sessionId, let snapshots {
            turns = await snapshots.snapshots(for: sessionId, repoRoot: root).recentTurns
            // A turn pinned by id that no longer exists (snapshots cleared) falls back to the newest.
            if let id = selectedTurnId, !turns.contains(where: { $0.id == id }) { selectedTurnId = nil }
        }
        if shouldReloadDiff { await loadDiff() }
    }

    private func reloadDiff() { diffTask?.cancel(); diffTask = Task { [weak self] in await self?.loadDiff() } }

    private func loadDiff() async {
        guard let repo else { files = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let diff = try await currentDiff(repo)
            guard !Task.isCancelled else { return }
            files = diff?.files ?? []
            fileSummaries = files.map(DiffFileSummary.init)
            rowCache.reset()
            text.clearTokens()
            highlightedFiles = []
            collapsed = []
            pagedFileCount = DiffPage.fileLimit(for: files, budget: Self.lineBudget)
            rebuildPage()
            error = nil
        } catch {
            files = []
            fileSummaries = []
            page = DiffPage()
            text.replace(document: DiffDocument(), keepingTokens: false)
            self.error = "\(error)"
            Self.log.error("diff panel load (\(self.scope.rawValue, privacy: .public)): \(error, privacy: .public)")
        }
    }

    /// The one place a scope becomes a pair of trees.
    private func currentDiff(_ repo: GitRepository) async throws -> UnifiedDiff? {
        switch scope {
        case .turn:
            guard let turn = selectedTurn, let snapshots else { return nil }
            return try await snapshots.store.diff(turn: turn)
        case .session:
            guard let sessionId, let snapshots else { return nil }
            let root = repo.root
            return try await snapshots.store.diffSinceSessionStart(sessionId, repoRoot: root)
        case .workingTree:
            switch workingSide {
            case .staged: return try await repo.diffAll(staged: true)
            case .unstaged: return try await repo.diffAll(staged: false)
            case .all:
                // HEAD → worktree in one pass, untracked files included: the snapshot machinery
                // already does exactly this, so the combined view is not a third diff path.
                guard let snapshots else { return try await repo.diffAll(staged: false) }
                let root = repo.root
                guard let head = try? await repo.tree(of: "HEAD"), !head.isEmpty else { return try await repo.diffAll(staged: false) }
                return try await repo.diff(from: head, toWorktree: await snapshots.store.scratch(for: root))
            }
        case .branch:
            if let sha = selectedCommit { return try await repo.diff(commit: sha) }
            guard let base = await repo.branchBaseRef() else { return UnifiedDiff() }
            return try await repo.diff(branchFrom: base)
        }
    }

    /// Reflows the rows for the current budget and collapse state, then asks for highlighting.
    /// The page is published first so the diff appears immediately and colours arrive after.
    private func rebuildPage() {
        page = DiffPage.build(files: files, collapsed: collapsed, limit: pagedFileCount, rowCache: rowCache)
        // Row ids are stable for the life of a diff, so colours already fetched survive a collapse
        // or a page extension — the document is rebuilt, the tokens are not.
        text.replace(document: DiffDocument.build(page: page), keepingTokens: true)
        highlightVisibleFiles()
    }

    /// Highlights only what has not been highlighted yet and merges the result in. Rebuilding the
    /// whole dictionary on every collapse re-parsed files that were already coloured.
    private func highlightVisibleFiles() {
        let pending = page.files.filter { !highlightedFiles.contains($0.path) && !$0.rows.isEmpty }
        guard !pending.isEmpty else { return }
        highlightTask?.cancel()
        let theme = DiffSyntaxTheme.current
        highlightTask = Task { [weak self, highlighter] in
            let result = await highlighter.highlights(for: pending, theme: theme)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.text.merge(tokens: result)
                self.highlightedFiles.formUnion(pending.map(\.path))
            }
        }
    }

    func showMoreFiles() {
        guard page.hasMore else { return }
        pagedFileCount += DiffPage.fileLimit(for: files, collapsed: collapsed, budget: Self.lineBudget, from: pagedFileCount)
        rebuildPage()
    }

    /// Extends the page until `path` is rendered. The rail lists every changed file, so a chip for
    /// a file still behind "Show more" has to bring it in rather than scroll to nothing.
    func reveal(path: String) -> Bool {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return false }
        if index >= pagedFileCount {
            pagedFileCount = index + 1
            rebuildPage()
        }
        return true
    }

    func toggleCollapsed(_ path: String) {
        if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
        rebuildPage()
    }

    func isCollapsed(_ path: String) -> Bool { collapsed.contains(path) }

    /// `-ClinicCollapseAllAfterLaunch`: collapses every rendered file one at a time, the way a
    /// reader would, and logs how long the whole run took. A click cannot be scripted; this is how
    /// the collapse path gets measured.
    func smokeCollapseAll() {
        let started = Date()
        let paths = page.files.map(\.path)
        for path in paths { toggleCollapsed(path) }
        Self.log.info("smokeCollapseAll: \(paths.count, privacy: .public) files in \(Date().timeIntervalSince(started) * 1000, privacy: .public) ms")
    }

    /// Fills `turnStats` for the turns the menu is about to show. Numstat only, never a patch.
    func loadTurnStats() {
        guard let repo, let snapshots else { return }
        let root = repo.root
        let missing = turns.filter { turnStats[$0.id] == nil }
        guard !missing.isEmpty else { return }
        Task { [weak self] in
            let scratch = await snapshots.store.scratch(for: root)
            for turn in missing {
                guard let head = turn.headTree else { continue }   // in flight: no fixed total yet
                guard let stat = try? await repo.stat(from: turn.baseTree, to: head, scratch: scratch) else { continue }
                await MainActor.run { self?.turnStats[turn.id] = stat }
            }
        }
    }

    // MARK: Empty states

    /// Why the current scope is showing nothing, when it is showing nothing.
    var emptyReason: String? {
        guard !isLoading, files.isEmpty, error == nil else { return nil }
        switch scope {
        case .turn:
            if sessionId == nil { return "Only sessions Clinic started record turns." }
            return turns.isEmpty ? "No turns recorded yet. The next prompt in this session starts one."
                                 : "This turn changed nothing on disk."
        case .session:
            return sessionId == nil ? "Only sessions Clinic started record turns." : "Nothing has changed since this session started."
        case .workingTree:
            return workingSide == .staged ? "Nothing is staged." : "The working tree is clean."
        case .branch:
            return selectedCommit == nil ? "This branch matches its base." : "This commit changed nothing."
        }
    }
}
