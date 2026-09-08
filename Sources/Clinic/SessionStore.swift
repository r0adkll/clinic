import Foundation
import Observation
import os
import ClinicCore

/// Everything known about sessions on disk plus Clinic's overlays (ADR-043). Main-actor observable model.
@MainActor
@Observable
final class SessionStore {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "sessions")

    private(set) var sessions: [SessionID: SessionSummary] = [:]
    /// Clinic-launched sessions whose transcript has not appeared on disk yet (ADR-017).
    private var pending: [SessionID: SessionSummary] = [:]
    private(set) var projects: [Project] = []
    private(set) var state = ClinicState()
    private(set) var isScanning = false
    var showArchived = false { didSet { rebuildProjects() } }
    private var archiveUndoStack: [(SessionID, RepoUpkeep.TrashedWorktree?)] = []

    private let scanner: SessionScanner
    private let watcher: DirectoryWatcher
    private let stateStore: StateStore
    private var watchTask: Task<Void, Never>?
    /// Completes after the first full scan; used by launch restoration.
    private(set) var initialScan: Task<Void, Never>?

    init(paths: ClaudePaths = ClaudePaths(), stateURL: URL = StateStore.defaultURL()) {
        scanner = SessionScanner(paths: paths)
        watcher = DirectoryWatcher(root: paths.projectsDirectory)
        stateStore = StateStore(url: stateURL)
        state = stateStore.initialState
    }

    func start() {
        initialScan = Task {
            await rescan()
            watcher.start()
            watchTask = Task { [watcher] in
                for await _ in watcher.changes { await self.rescan() }
            }
        }
    }

    func rescan() async {
        isScanning = true
        let found = await scanner.scanAll()
        var map: [SessionID: SessionSummary] = [:]
        for s in found { map[s.id] = s; pending[s.id] = nil }
        for (id, p) in pending where map[id] == nil { map[id] = p }
        sessions = map
        // Owned ids whose transcript never appeared (a session closed before its first prompt while the app was quit) are stale.
        let stale = state.ownedSessions.keys.filter { map[$0] == nil }
        if !stale.isEmpty { update { s in for id in stale { s.ownedSessions[id] = nil } } }
        rebuildProjects()
        isScanning = false
    }

    /// Re-read one transcript (called when a hook reports activity so the sidebar updates before the watcher fires).
    func refresh(transcriptPath: String) async {
        if let s = await scanner.scan(file: URL(fileURLWithPath: transcriptPath)) {
            pending[s.id] = nil
            sessions[s.id] = s
            rebuildProjects()
        }
    }

    /// Shared scratch directory for chats (ADR-068).
    static let chatsDirectory: String = ClinicPaths.appSupport.appendingPathComponent("Clinic/Chats", isDirectory: true).path
    static func isChats(_ path: String) -> Bool { path == chatsDirectory }

    private func rebuildProjects() {
        var byPath: [String: Date] = [:]
        for s in sessions.values {
            guard isVisible(s), let p = ProjectGrouping.project(for: s) else { continue }
            byPath[p.path] = max(byPath[p.path] ?? .distantPast, s.activityDate)
        }
        for added in state.addedProjects where byPath[added] == nil && !state.removedProjects.contains(added) { byPath[added] = .distantPast }
        // ADR-062: manual order first, then the rest by activity.
        let chats = byPath[Self.chatsDirectory] != nil ? [Self.chatsDirectory] : []
        let pinned = state.projectOrder.filter { byPath[$0] != nil && !Self.isChats($0) }
        let rest = byPath.keys.filter { !pinned.contains($0) && !Self.isChats($0) }.sorted { (byPath[$0]!, $0) > (byPath[$1]!, $1) }
        projects = (chats + pinned + rest).map(Project.init(path:))
    }

    // MARK: Project groups (ADR-062)

    func isCollapsed(_ project: Project) -> Bool { state.collapsedProjects.contains(project.path) }
    func setCollapsed(_ project: Project, _ collapsed: Bool) {
        let path = project.path
        update { s in if collapsed { s.collapsedProjects.insert(path) } else { s.collapsedProjects.remove(path) } }
    }
    func collapseAll() { let all = Set(projects.map(\.path)); update { s in s.collapsedProjects = all } }
    func expandAll() { update { s in s.collapsedProjects = [] } }

    /// Moves `path` so it sits at `target`'s position; writes the complete visible order.
    func moveProject(_ path: String, before target: String) {
        guard path != target else { return }
        var order = projects.map(\.path)
        guard let from = order.firstIndex(of: path), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        let insertAt = order.firstIndex(of: target) ?? to
        order.insert(path, at: insertAt)
        let final = order
        update { s in s.projectOrder = final }
    }

    func resetProjectOrder() { update { s in s.projectOrder = [] } }

    func addProject(_ path: String) {
        update { s in
            s.removedProjects.remove(path)
            if !s.addedProjects.contains(path) { s.addedProjects.append(path) }
        }
    }

    var sessionSort: String { UserDefaults.standard.string(forKey: "ClinicSessionSort") ?? "activity" }

    /// Sessions for a project, most recent first (ADR-040). Archived hidden unless `showArchived`.
    func sessions(in project: Project) -> [SessionSummary] {
        let byCreated = sessionSort == "created"
        return sessions.values
            .filter { isVisible($0) && ProjectGrouping.project(for: $0)?.path == project.path }
            .sorted { a, b in
                let ka = byCreated ? (a.createdAt ?? a.activityDate) : a.activityDate
                let kb = byCreated ? (b.createdAt ?? b.activityDate) : b.activityDate
                return (ka, a.id.rawValue) > (kb, b.id.rawValue)
            }
    }

    /// Favorited sessions across projects, most recent first.
    var favoriteSessions: [SessionSummary] {
        state.favorites.compactMap { sessions[$0] }.filter(isVisible)
            .sorted { ($0.activityDate, $0.id.rawValue) > ($1.activityDate, $1.id.rawValue) }
    }

    /// ADR-048: only owned sessions unless the hidden preference shows discovered ones; removed projects hide their sessions.
    func isVisible(_ s: SessionSummary) -> Bool {
        guard showArchived || state.archived[s.id] == nil else { return false }
        guard let p = ProjectGrouping.project(for: s), !state.removedProjects.contains(p.path) else { return false }
        return isOwned(s.id) || UserDefaults.standard.bool(forKey: "ClinicShowDiscoveredSessions")
    }

    func isOwned(_ id: SessionID) -> Bool { state.ownedSessions[id] != nil }

    /// Adopts an on-disk session into Clinic (Import).
    func adopt(_ summary: SessionSummary) {
        guard !isOwned(summary.id) else { return }
        let path = ProjectGrouping.project(for: summary)?.path ?? summary.cwd ?? ""
        update { s in
            s.ownedSessions[summary.id] = ClinicState.OwnedSession(projectPath: path, imported: true)
            s.removedProjects.remove(path)
        }
    }

    /// All on-disk sessions for the switcher, owned first, then the rest.
    func allSessions(matching query: String) -> [SessionSummary] {
        sessions.values
            .filter { state.archived[$0.id] == nil && matches($0, query: query) }
            .sorted { a, b in
                let ao = isOwned(a.id), bo = isOwned(b.id)
                if ao != bo { return ao }
                return (a.activityDate, a.id.rawValue) > (b.activityDate, b.id.rawValue)
            }
    }

    /// PRs attached by the `attach_pr` tool are merged into the session's transcript-derived list.
    func attachPullRequest(_ ref: PullRequestRef, to id: SessionID) {
        guard var s = sessions[id], !s.pullRequests.contains(where: { $0.url == ref.url }) else { return }
        s.pullRequests.append(ref)
        sessions[id] = s
        pending[id] = pending[id] != nil ? s : nil
    }

    func removeProject(_ project: Project) {
        update { s in
            s.removedProjects.insert(project.path)
            s.addedProjects.removeAll { $0 == project.path }
        }
    }
    func isArchived(_ id: SessionID) -> Bool { state.archived[id] != nil }
    func isFavorite(_ id: SessionID) -> Bool { state.favorites.contains(id) }

    // MARK: Overlays (ADR-018: Clinic-side only)

    func rename(_ id: SessionID, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        update { s in if let trimmed, !trimmed.isEmpty { s.manualNames[id] = trimmed } else { s.manualNames[id] = nil } }
    }

    func toggleFavorite(_ id: SessionID) {
        update { s in if s.favorites.contains(id) { s.favorites.remove(id) } else { s.favorites.insert(id) } }
    }

    var onArchive: ((SessionID) -> Void)?

    func archive(_ id: SessionID, trashedWorktree: RepoUpkeep.TrashedWorktree? = nil) {
        archiveUndoStack.append((id, trashedWorktree))
        onArchive?(id)
        update { s in s.archived[id] = Date() }
    }

    /// Archives every visible session of a project and hides the project (ADR-065).
    func archiveProject(_ project: Project) {
        let ids = sessions(in: project).map(\.id)
        for id in ids { archiveUndoStack.append((id, nil)) }
        update { s in for id in ids { s.archived[id] = Date() }; s.addedProjects.removeAll { $0 == project.path } }
    }

    func unarchive(_ id: SessionID) {
        update { s in s.archived[id] = nil }
    }

    var canUndoArchive: Bool { !archiveUndoStack.isEmpty }

    func undoArchive() {
        guard let (id, trashed) = archiveUndoStack.popLast() else { return }
        unarchive(id)
        if let trashed { Task { await RepoUpkeep.restore(trashed) } }
    }

    /// Case-insensitive substring match over name, prompt, project, branch and id. Empty query matches everything.
    func matches(_ s: SessionSummary, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let hay = [displayName(for: s), s.firstPrompt ?? "", ProjectGrouping.project(for: s)?.name ?? "", s.gitBranch ?? "", s.id.rawValue]
        return q.split(separator: " ").allSatisfy { term in hay.contains { $0.lowercased().contains(term) } }
    }

    func displayName(for session: SessionSummary) -> String {
        SessionNaming.displayName(for: session, manualName: state.manualNames[session.id])
    }

    func update(_ mutate: @escaping @Sendable (inout ClinicState) -> Void) {
        mutate(&state)
        rebuildProjects()
        Task { await stateStore.update(mutate) }
    }

    func flush() async { await stateStore.flush() }

    /// Drops a placeholder whose transcript never appeared (tab closed before the first prompt).
    func removePending(id: SessionID) {
        guard pending[id] != nil, !FileManager.default.fileExists(atPath: sessions[id]?.transcriptPath ?? "") else { return }
        pending[id] = nil
        sessions[id] = nil
        update { s in s.ownedSessions[id] = nil }
    }

    /// Placeholder rows for sessions launched by Clinic whose transcript does not exist yet (ADR-017).
    func registerPending(id: SessionID, cwd: String, title: String = "New session") {
        guard sessions[id] == nil else { return }
        let paths = ClaudePaths()
        let path = paths.projectsDirectory.appendingPathComponent(ClaudePaths.encodedProjectDirectoryName(for: cwd)).appendingPathComponent("\(id.rawValue).jsonl").path
        let placeholder = SessionSummary(id: id, transcriptPath: path, cwd: cwd, firstPrompt: title, createdAt: Date(), lastActivityAt: Date(), fileModifiedAt: Date())
        pending[id] = placeholder
        sessions[id] = placeholder
        update { s in
            s.ownedSessions[id] = ClinicState.OwnedSession(projectPath: ProjectGrouping.projectPath(forCwd: cwd))
            s.removedProjects.remove(ProjectGrouping.projectPath(forCwd: cwd))
        }
    }
}
