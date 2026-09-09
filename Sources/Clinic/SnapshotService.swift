import Foundation
import Observation
import os
import ClinicCore

/// Drives `SnapshotStore` from the hook stream (ADR-080): the diff panel's turn history is a
/// side effect of events ADR-027 already installs, so nothing new is asked of Claude Code.
@MainActor
@Observable
final class SnapshotService {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "snapshots")

    let store: SnapshotStore
    /// Bytes on disk, refreshed on demand for Preferences → Diagnostics.
    private(set) var diskUsage: Int64 = 0

    /// Repo root per session, resolved once from the session's cwd. A session whose cwd is not in a
    /// repository maps to nil and is skipped for the rest of its life in this tab.
    private var repoRoots: [SessionID: String?] = [:]

    /// Events are handled one at a time, in arrival order: `beginTurn` must never overtake the
    /// `endTurn` before it, and two snapshots of one repo would fight over the same scratch index.
    private var queue: AsyncStream<Job>.Continuation?
    private var pump: Task<Void, Never>?

    private struct Job: Sendable { var trigger: SnapshotTrigger; var session: SessionID; var cwd: String?; var at: Date }

    init(store: SnapshotStore = SnapshotStore()) {
        self.store = store
        let (stream, continuation) = AsyncStream<Job>.makeStream(bufferingPolicy: .unbounded)
        queue = continuation
        pump = Task { [weak self] in
            for await job in stream {
                guard let self else { return }
                await self.perform(job)
            }
        }
    }

    /// No `deinit` teardown: the continuation dies with the service, which finishes the stream and
    /// ends the pump on its own (and a `deinit` cannot touch main-actor state anyway).
    func stop() { pump?.cancel(); pump = nil; queue?.finish(); queue = nil }

    // MARK: Hook stream

    /// Called for every hook event of a session tab. `cwd` is the tab's best known directory, since
    /// only some events carry one. Which events matter is `SnapshotTrigger`'s decision, not ours.
    func handle(_ event: HookEvent, cwd: String?) {
        guard let trigger = SnapshotTrigger(event: event) else { return }
        queue?.yield(Job(trigger: trigger, session: event.sessionId, cwd: event.cwd ?? cwd, at: event.receivedAt))
    }

    private func perform(_ job: Job) async {
        guard let root = await repoRoot(for: job.session, cwd: job.cwd) else { return }
        await store.record(job.trigger, session: job.session, repoRoot: root, at: job.at)
    }

    private func repoRoot(for session: SessionID, cwd: String?) async -> String? {
        if let known = repoRoots[session] { return known }
        guard let cwd else { return nil }   // not cached: a later event with a cwd can still resolve it
        let root = await GitRepository.discover(from: cwd)?.root
        repoRoots[session] = root
        if root == nil { Self.log.debug("no repository at \(cwd, privacy: .public); session takes no snapshots") }
        return root
    }

    /// Forgets a session's resolved repo, so a tab that moves to another repository (a new worktree,
    /// a `cd`) starts a fresh lineage rather than diffing unrelated trees.
    func forget(session: SessionID) { repoRoots.removeValue(forKey: session) }

    // MARK: Reading

    func repoRoot(for session: SessionID) -> String? { repoRoots[session] ?? nil }

    func snapshots(for session: SessionID, repoRoot: String) async -> SessionSnapshots {
        await store.snapshots(session: session, repoRoot: repoRoot)
    }

    // MARK: Housekeeping

    /// Drops snapshots of repositories nothing has used lately, and refreshes the Diagnostics readout.
    /// The repos of sessions this launch has already resolved are kept whatever their age.
    func sweep() {
        let live = Set(repoRoots.values.compactMap { $0 })
        Task { [store] in
            let dropped = await store.prune(keeping: live)
            if !dropped.isEmpty { Self.log.info("pruned \(dropped.count) stale snapshot store(s)") }
            let usage = await store.diskUsage()
            await MainActor.run { self.diskUsage = usage }
        }
    }

    func refreshDiskUsage() {
        Task { [store] in
            let usage = await store.diskUsage()
            await MainActor.run { self.diskUsage = usage }
        }
    }

    func clear() {
        repoRoots.removeAll()
        Task { [store] in
            await store.removeAll()
            await MainActor.run { self.diskUsage = 0 }
        }
    }
}
