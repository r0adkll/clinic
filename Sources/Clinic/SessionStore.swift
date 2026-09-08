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
    private var archiveUndoStack: [SessionID] = []

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

    private func rebuildProjects() {
        var byPath: [String: Date] = [:]
        for s in sessions.values {
            guard isVisible(s), let p = ProjectGrouping.project(for: s) else { continue }
            byPath[p.path] = max(byPath[p.path] ?? .distantPast, s.activityDate)
        }
        for added in state.addedProjects where byPath[added] == nil && !state.removedProjects.contains(added) { byPath[added] = .distantPast }
        projects = byPath.keys.sorted { (byPath[$0]!, $0) > (byPath[$1]!, $1) }.map(Project.init(path:))
    }

    /// Sessions for a project, most recent first (ADR-040). Archived hidden unless `showArchived`.
    func sessions(in project: Project) -> [SessionSummary] {
        sessions.values
            .filter { isVisible($0) && ProjectGrouping.project(for: $0)?.path == project.path }
            .sorted { ($0.activityDate, $0.id.rawValue) > ($1.activityDate, $1.id.rawValue) }
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

    func archive(_ id: SessionID) {
        archiveUndoStack.append(id)
        update { s in s.archived[id] = Date() }
    }

    func unarchive(_ id: SessionID) {
        update { s in s.archived[id] = nil }
    }

    var canUndoArchive: Bool { !archiveUndoStack.isEmpty }

    func undoArchive() {
        guard let id = archiveUndoStack.popLast() else { return }
        unarchive(id)
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
    func registerPending(id: SessionID, cwd: String) {
        guard sessions[id] == nil else { return }
        let paths = ClaudePaths()
        let path = paths.projectsDirectory.appendingPathComponent(ClaudePaths.encodedProjectDirectoryName(for: cwd)).appendingPathComponent("\(id.rawValue).jsonl").path
        let placeholder = SessionSummary(id: id, transcriptPath: path, cwd: cwd, firstPrompt: "New session", createdAt: Date(), lastActivityAt: Date(), fileModifiedAt: Date())
        pending[id] = placeholder
        sessions[id] = placeholder
        update { s in
            s.ownedSessions[id] = ClinicState.OwnedSession(projectPath: ProjectGrouping.projectPath(forCwd: cwd))
            s.removedProjects.remove(ProjectGrouping.projectPath(forCwd: cwd))
        }
    }
}
