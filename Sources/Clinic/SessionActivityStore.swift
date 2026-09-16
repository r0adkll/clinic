import Foundation
import Observation
import ClinicCore

/// What each live session is doing, for the sidebar's cards (ADR-156).
///
/// A session is live while it is open in a tab or running detached. Each live transcript gets a
/// `TranscriptFollower` and a vnode watch; an append re-reads only the new bytes. The set is
/// reconciled every two seconds against `liveProvider` rather than threaded through every place a
/// tab opens, closes or rebinds its id — a set comparison is cheaper than getting one of those wrong.
@MainActor
@Observable
final class SessionActivityStore {
    private(set) var activities: [SessionID: SessionActivity] = [:]

    /// Live sessions and their transcript paths. Set by the app delegate.
    @ObservationIgnored var liveProvider: (() -> [SessionID: String])?
    @ObservationIgnored private var followers: [SessionID: TranscriptFollower] = [:]
    @ObservationIgnored private let watcher = PathWatcher(debounce: 0.25)
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTimer: Timer?

    func activity(for id: SessionID) -> SessionActivity? { activities[id] }

    func start() {
        guard reconcileTimer == nil else { return }
        let changes = watcher.changes
        watchTask = Task { [weak self] in
            for await _ in changes { await self?.pollAll() }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
        reconcile()
    }

    func stop() {
        reconcileTimer?.invalidate(); reconcileTimer = nil
        watchTask?.cancel(); watchTask = nil
        watcher.stop()
    }

    /// A hook said something happened; read now rather than waiting for the watcher's debounce.
    func nudge() { Task { await pollAll() } }

    private func reconcile() {
        let live = liveProvider?() ?? [:]
        var changed = false
        for id in followers.keys where live[id] == nil {
            followers[id] = nil
            activities[id] = nil
            changed = true
        }
        for (id, path) in live where followers[id]?.path != path {
            followers[id] = TranscriptFollower(path: path)
            activities[id] = nil
            changed = true
        }
        guard changed else { return }
        watcher.watch(Set(followers.values.map(\.path)))
        Task { await pollAll() }
    }

    private func pollAll() async {
        for (id, follower) in followers {
            guard let activity = await follower.poll() else { continue }
            // The session may have closed, or its transcript moved, while the read was in flight.
            guard followers[id] === follower, activities[id] != activity else { continue }
            activities[id] = activity
        }
    }
}
