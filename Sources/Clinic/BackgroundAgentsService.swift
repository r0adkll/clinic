import AppKit
import Observation
import os
import ClinicCore

/// Polls `claude agents --json --all` and surfaces detached sessions (ADR-061).
@MainActor
@Observable
final class BackgroundAgentsService {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "background")
    private(set) var agents: [BackgroundAgent] = []
    private(set) var lastRefresh: Date?
    private var pollTask: Task<Void, Never>?
    private var lastStates: [String: String] = [:]
    private weak var sessions: SessionStore?
    private weak var history: NotificationStore?
    private weak var notifications: NotificationService?
    var isAttachedProvider: (() -> Bool)?
    /// Set by the app to route through TabStore.notify (ADR-066).
    var router: ((SessionID, String, String, NotificationStore.Entry.Kind) -> Void)?
    static let interval: Duration = .seconds(15)

    var background: [BackgroundAgent] { agents.filter(\.isBackground) }
    func agent(for sessionId: SessionID) -> BackgroundAgent? { background.first { $0.sessionId == sessionId } }
    func runningAgent(for sessionId: SessionID) -> BackgroundAgent? { agent(for: sessionId).flatMap { $0.isRunning ? $0 : nil } }

    func start(sessions: SessionStore, history: NotificationStore, notifications: NotificationService) {
        self.sessions = sessions; self.history = history; self.notifications = notifications
        pollTask = Task { [weak self] in
            await sessions.initialScan?.value   // sessions must exist before detached ones can be adopted
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Poll faster only while something detached exists or a tab is attached; otherwise back off.
                let active = !self.background.filter(\.isRunning).isEmpty || (self.isAttachedProvider?() ?? false)
                try? await Task.sleep(for: active ? Self.interval : .seconds(60))
            }
        }
    }

    func stop() { pollTask?.cancel() }

    func refresh() async {
        let list = await BackgroundAgentsCLI.list()
        agents = list
        lastRefresh = Date()
        for a in list where a.isBackground {
            if let sid = a.sessionId, let s = sessions?.sessions[sid], sessions?.isOwned(sid) == false { sessions?.adopt(s) }
            let key = a.state ?? a.status
            // The trigger set lives on BackgroundAgent so it cannot drift from `isRunning`: the CLI
            // reports `done` rather than the documented `completed`, so this list silently never
            // fired on a normal finish (ADR-095).
            if let old = lastStates[a.id], old != key, BackgroundAgent.announcedStates.contains(key) { announce(a, transition: key) }
            lastStates[a.id] = key
        }
        for id in lastStates.keys where !list.contains(where: { $0.id == id }) { lastStates[id] = nil }
    }

    private func announce(_ a: BackgroundAgent, transition: String) {
        let title = a.name ?? a.sessionId.flatMap { sessions?.sessions[$0].map { sessions!.displayName(for: $0) } } ?? "Background session"
        let body: String
        let kind: NotificationStore.Entry.Kind
        switch transition {
        case "needs_input", "blocked": body = "Detached session needs you" + (a.waitingFor.map { " (\($0))" } ?? ""); kind = .needsInput
        case "failed": body = "Detached session failed"; kind = .error
        default: body = "Detached session finished"; kind = .finished
        }
        guard let sid = a.sessionId else { return }
        if let router { router(sid, title, body, kind) }
        else {
            history?.record(sessionId: sid, title: title, body: body, kind: kind)
            if !(sessions?.state.mutedSessions.contains(sid) ?? false) { notifications?.post(sessionId: sid, title: title, body: body) }
        }
    }

    func stopAgent(_ a: BackgroundAgent) async { _ = await BackgroundAgentsCLI.stop(a.id); await refresh() }
    func removeAgent(_ a: BackgroundAgent) async { _ = await BackgroundAgentsCLI.remove(a.id); await refresh() }
}
