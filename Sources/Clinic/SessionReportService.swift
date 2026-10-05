import AppKit
import Observation
import os
import ClinicCore

/// Carries a child's report to its parent (ADR-182): pastes it when the parent can take a prompt,
/// holds it otherwise, reminds a child that stops without reporting, and resolves a parent's
/// `start_session(wait: true)` with the first report.
@MainActor
@Observable
final class SessionReportService {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "reports")
    private weak var tabs: TabStore?
    private weak var sessions: SessionStore?
    private weak var agents: BackgroundAgentsService?

    struct WaitEnded: Error { let reason: String }

    /// Parents blocked in `start_session(wait: true)`, and the child each one waits for once known.
    @ObservationIgnored private var waiters: [SessionID: CheckedContinuation<String, Error>] = [:]
    private(set) var waitingChild: [SessionID: SessionID?] = [:]

    func start(tabs: TabStore, sessions: SessionStore, agents: BackgroundAgentsService) {
        self.tabs = tabs; self.sessions = sessions; self.agents = agents
    }

    // MARK: Arming

    /// A child that reports to its parent: the tool is listed for it and the brief asks for a report.
    func arm(child: SessionID) {
        sessions?.update { s in if s.childReporting[child] == nil { s.childReporting[child] = ChildReporting() } }
    }

    func isReporting(_ child: SessionID) -> Bool {
        guard let sessions else { return false }
        return sessions.state.childReporting[child] != nil && sessions.parent(of: child) != nil
    }

    func isPaused(_ child: SessionID) -> Bool { sessions?.state.childReporting[child]?.paused ?? false }

    /// Off holds rather than drops; on delivers what was held.
    func setPaused(_ child: SessionID, _ paused: Bool) {
        sessions?.update { s in s.childReporting[child]?.paused = paused }
        if !paused, let parent = sessions?.parent(of: child)?.id { deliverPending(to: parent) }
    }

    // MARK: The brief

    /// What the child is told about its situation, for `--append-system-prompt`. The parent's peer
    /// name comes from the agents poll when it has seen the parent; otherwise that sentence is left out.
    func brief(parent: SessionID, parentTitle: String, directory: String, reporting: Bool) -> String {
        let peer = agents?.agents.first { $0.sessionId == parent }?.name
        return SessionReporting.brief(parentTitle: parentTitle, peerName: peer, directory: directory, reporting: reporting)
    }

    // MARK: Reports

    /// `report_to_parent`: what the tool answers.
    func report(from child: SessionID, message: String) -> String {
        guard let sessions, let tabs, let parent = sessions.parent(of: child)?.id else { return "This session has no parent session to report to." }
        guard isReporting(child) else { return "This session was not started with reporting on." }
        let parentTitle = sessions.sessions[parent].map(sessions.displayName(for:)) ?? "the parent session"
        // A parent blocked in start_session(wait:) takes the first report as its tool result.
        if let cont = waiters.removeValue(forKey: parent), waitingChild[parent] == nil || waitingChild[parent] == child {
            waitingChild[parent] = nil
            let now = Date()
            sessions.update { s in s.addReport(SessionReport(from: child, message: message, at: now, deliveredAt: now), to: parent) }
            cont.resume(returning: message)
            Self.log.info("report from \(child.rawValue, privacy: .public) resolved the wait of \(parent.rawValue, privacy: .public)")
            return "Delivered to \"\(parentTitle)\" as the result of its start_session call."
        }
        let report = SessionReport(from: child, message: message)
        sessions.update { s in s.addReport(report, to: parent) }
        if deliver(report, to: parent) { return "Delivered to \"\(parentTitle)\" as its next prompt." }
        let reason = holdReason(parent: parent, child: child)
        if tabs.tab(for: parent) == nil {
            let childTitle = sessions.sessions[child].map(sessions.displayName(for:)) ?? "A child session"
            tabs.notify(nil, sessionId: parent, title: childTitle, body: "Finished; report waiting for \"\(parentTitle)\"", kind: .finished)
        }
        return "Held: \(reason). Clinic delivers it to \"\(parentTitle)\" as soon as that session can take a prompt."
    }

    /// Why a report is waiting, in words for the child and the card.
    func holdReason(parent: SessionID, child: SessionID) -> String {
        if isPaused(child) { return "the user turned reporting off for this session" }
        guard let tab = tabs?.tab(for: parent) else { return "the parent session is not open" }
        switch tab.state {
        case .waitingForPermission: return "the parent session is at a permission prompt"
        case .waitingForInput: return "the parent session is in a dialog"
        case .launching: return "the parent session is starting"
        case .exited: return "the parent session has exited"
        default: return "the parent session cannot take a prompt right now"
        }
    }

    @discardableResult
    private func deliver(_ report: SessionReport, to parent: SessionID) -> Bool {
        guard let sessions, let tabs, !isPaused(report.from), let tab = tabs.tab(for: parent), !tab.awaitingId,
              SessionReporting.canDeliver(state: tab.state, waitingOn: tab.waitingOn) else { return false }
        let child = sessions.sessions[report.from]
        let title = child.map(sessions.displayName(for:)) ?? "a child session"
        let project = child.flatMap(ProjectGrouping.project(for:))?.name
        let text = SessionReporting.compose(header: SessionReporting.header(childTitle: title, project: project, id: report.from), message: report.message)
        tab.surface.sendPastedLine(text)
        let now = Date()
        sessions.update { s in
            guard var list = s.reports[parent], let i = list.firstIndex(where: { $0.id == report.id }) else { return }
            list[i].deliveredAt = now
            s.reports[parent] = list
        }
        Self.log.info("delivered a report from \(report.from.rawValue, privacy: .public) to \(parent.rawValue, privacy: .public)")
        return true
    }

    /// Everything held for `parent`, oldest first, until one cannot go. Called when the parent's state
    /// moves, when its tab opens, and when a child's reporting is turned back on.
    func deliverPending(to parent: SessionID) {
        guard let sessions else { return }
        for r in sessions.state.pendingReports(for: parent) { if !deliver(r, to: parent) { break } }
    }

    func pendingReports(for parent: SessionID) -> [SessionReport] { sessions?.state.pendingReports(for: parent) ?? [] }

    func reports(for parent: SessionID) -> [SessionReport] { sessions?.state.reports[parent] ?? [] }

    // MARK: The reminder

    /// A reporting child ended a turn. Once, if it has never reported, it is reminded; after the CLI
    /// has shown its prompt, so the paste lands as the next one.
    func childStopped(_ child: SessionID) {
        guard let sessions, isReporting(child), let st = sessions.state.childReporting[child],
              st.reportedAt == nil, st.remindedAt == nil else { return }
        sessions.update { s in s.childReporting[child]?.remindedAt = Date() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let tab = self?.tabs?.tab(for: child), tab.isAtPrompt else { return }
            tab.surface.sendPastedLine(SessionReporting.reminder)
            Self.log.info("reminded \(child.rawValue, privacy: .public) to report")
        }
    }

    // MARK: Waiting (`start_session(wait: true)`)

    /// Holds the parent's tool call until a child's first report. `child` is nil for a fork whose id is
    /// not known yet; the first report from any child of the parent then resolves it.
    func awaitFirstReport(for parent: SessionID, from child: SessionID?) async throws -> String {
        if let old = waiters.removeValue(forKey: parent) { old.resume(throwing: WaitEnded(reason: "a newer start_session call replaced this wait")) }
        return try await withCheckedThrowingContinuation { cont in
            waiters[parent] = cont
            waitingChild[parent] = child
        }
    }

    /// A fork learned its id: the wait on its parent now names it.
    func childIdentified(_ child: SessionID, parent: SessionID) {
        if waiters[parent] != nil, waitingChild[parent] == nil { waitingChild[parent] = child }
    }

    /// The child's tab closed, its process exited or the user stopped it: a waiting parent is told.
    func childEnded(_ child: SessionID, reason: String) {
        guard let parent = sessions?.parent(of: child)?.id, let cont = waiters[parent],
              waitingChild[parent] == nil || waitingChild[parent] == child else { return }
        waiters[parent] = nil
        waitingChild[parent] = nil
        cont.resume(throwing: WaitEnded(reason: reason))
    }

    /// The child a parent's card says it is waiting for, if any.
    func isWaiting(_ parent: SessionID) -> Bool { waiters[parent] != nil }
    func waitedChild(of parent: SessionID) -> SessionID? { waitingChild[parent] ?? nil }
}
