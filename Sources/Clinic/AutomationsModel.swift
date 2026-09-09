import Foundation
import Observation
import os
import ClinicCore

/// Drives scheduled sessions: one timer, the launches it causes, and what becomes of them (ADR-095).
///
/// There is exactly **one scheduler** in Clinic. The launchd agent behind the *Run automations when
/// Clinic isn't open* preference is a wake-up, not a second scheduler — it starts the app hidden and
/// this model's ordinary catch-up pass does the work. That is why nothing here knows about launchd.
///
/// An automation run is a background agent, so almost nothing downstream lives here: the state
/// machine, the sidebar row, attention, the transcript and the diff snapshots all come from the hooks
/// the launch registers ([[ADR-061]]).
@MainActor
@Observable
final class AutomationsModel {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "automations")

    private(set) var automations: [Automation] = []
    /// Mirrored out of the actor so SwiftUI can read it without awaiting.
    private(set) var runs: [UUID: [AutomationRun]] = [:]
    /// Selection in the screen's list. nil shows the template gallery.
    var selectedId: UUID?
    /// The editor, presented over the screen. nil when it is just a list.
    var draft: AutomationDraft?
    /// A removal waiting on confirmation, because `claude rm` takes the worktree and branch with it.
    var pendingRemoval: PendingRemoval?
    /// Last launch failure, shown on the screen rather than only in the log.
    var lastError: String?
    private(set) var nextWakeUp: Date?

    private let runStore: AutomationRunStore
    private let runner = AutomationRunner()
    private weak var sessions: SessionStore?
    private var settingsFilePath = ""
    private var chatsDirectory = ""
    private var timerTask: Task<Void, Never>?
    /// When a run was first seen waiting on the user, so the stall timeout is measured from the wait
    /// rather than from the launch.
    private var waitingSince: [UUID: Date] = [:]

    var router: ((SessionID?, String, String, NotificationStore.Entry.Kind) -> Void)?

    struct PendingRemoval: Identifiable {
        let id = UUID()
        var run: AutomationRun
        var automationName: String
        var command: String
    }

    init(runStoreURL: URL = AutomationRunStore.defaultURL()) {
        runStore = AutomationRunStore(url: runStoreURL)
    }

    // MARK: - Lifecycle

    func start(sessions: SessionStore, settingsFilePath: String, chatsDirectory: String) {
        self.sessions = sessions
        self.settingsFilePath = settingsFilePath
        self.chatsDirectory = chatsDirectory
        automations = sessions.state.automations
        Task { await self.refreshRuns(); await self.tick() }
    }

    func stop() { timerTask?.cancel(); timerTask = nil }

    /// Arms a single timer for the soonest due automation. No polling: with nothing scheduled, no
    /// timer exists at all.
    private func armTimer() {
        timerTask?.cancel()
        guard let next = AutomationScheduler.nextWakeUp(for: automations) else {
            nextWakeUp = nil
            return
        }
        nextWakeUp = next
        let delay = max(1, next.timeIntervalSinceNow)
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.tick()
        }
    }

    /// Decides for every automation and acts. Runs on launch, when the timer fires, and when the app
    /// is woken — the catch-up path and the on-time path are deliberately the same code.
    func tick() async {
        for automation in automations {
            let active = await runStore.activeRun(for: automation.id) != nil
            switch AutomationScheduler.decide(for: automation, activeRun: active) {
            case .fire(let scheduledFor):
                await fire(automation, scheduledFor: scheduledFor)
            case .skip(let reason, let scheduledFor):
                await recordSkip(automation, reason: reason, scheduledFor: scheduledFor)
            case .wait, .idle:
                continue
            }
        }
        await refreshRuns()
        armTimer()
    }

    // MARK: - Firing

    func runNow(_ automation: Automation) {
        Task {
            let active = await runStore.activeRun(for: automation.id) != nil
            guard !active else {
                lastError = "\(automation.name) is already running."
                return
            }
            await fire(automation, scheduledFor: Date(), manual: true)
            await refreshRuns()
        }
    }

    private func fire(_ automation: Automation, scheduledFor: Date, manual: Bool = false) async {
        let directory = automation.workingDirectory(chatsDirectory: chatsDirectory)
        guard FileManager.default.fileExists(atPath: directory) else {
            await recordSkip(automation, reason: .projectMissing, scheduledFor: scheduledFor)
            return
        }
        // Chats share one pre-trusted scratch directory, so a chat automation never meets a trust
        // prompt it cannot answer (ADR-068).
        if case .chat = automation.target {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        let launch = AutomationLauncher.launch(for: automation, fireDate: scheduledFor,
                                               settingsFilePath: settingsFilePath)
        var run = AutomationRun(automationId: automation.id, scheduledFor: scheduledFor,
                                worktreeName: launch.worktreeName, cwd: directory)
        await runStore.record(run)
        if !manual { markFired(automation, at: scheduledFor) }

        let outcome = await runner.launch(launch, in: directory)
        if outcome.isSuccess {
            run.agentId = outcome.agentId
            Self.log.info("automation \(automation.name, privacy: .public) launched as \(outcome.agentId ?? "?", privacy: .public)")
        } else {
            run.outcome = .launchFailed(message: outcome.output.isEmpty ? "claude --bg exited \(outcome.status)" : outcome.output)
            run.finishedAt = Date()
            lastError = "\(automation.name): \(run.outcome.title)"
            notify(automation, run: run)
        }
        await runStore.record(run)
        await refreshRuns()
    }

    private func recordSkip(_ automation: Automation, reason: AutomationRun.SkipReason, scheduledFor: Date) async {
        let run = AutomationRun(automationId: automation.id, scheduledFor: scheduledFor,
                                finishedAt: Date(), outcome: .skipped(reason: reason))
        await runStore.record(run)
        // A skipped fire still advances the clock, or the same missed fire is reconsidered for ever.
        markFired(automation, at: scheduledFor)
    }

    private func markFired(_ automation: Automation, at date: Date) {
        guard let i = automations.firstIndex(where: { $0.id == automation.id }) else { return }
        automations[i].lastFiredAt = date
        persist()
    }

    // MARK: - Reconciliation

    /// Called after every `claude agents --json` refresh. The background-agent poll is the completion
    /// signal rather than a hook, because `--bg` finishing does not send `SessionEnd` — the process
    /// stays resident and reports `state: done`.
    func reconcile(agents: [BackgroundAgent]) {
        Task { await reconcileAsync(agents: agents) }
    }

    private func reconcileAsync(agents: [BackgroundAgent]) async {
        let running = await runStore.allRunning()
        guard !running.isEmpty else { return }
        for run in running {
            guard let agentId = run.agentId,
                  let agent = agents.first(where: { $0.id == agentId || $0.sessionId == run.sessionId })
            else { continue }

            if agent.isRunning {
                await checkForStall(run, agent: agent)
                continue
            }
            var finished = run
            finished.outcome = agent.state == "failed" ? .failed : .finished
            finished.finishedAt = Date()
            finished.sessionId = finished.sessionId ?? agent.sessionId
            await settle(finished)
        }
        await refreshRuns()
    }

    /// A run waiting on the user past its automation's timeout is stopped and recorded, rather than
    /// left holding a worktree until morning.
    private func checkForStall(_ run: AutomationRun, agent: BackgroundAgent) async {
        guard agent.needsAttention else {
            waitingSince[run.id] = nil
            return
        }
        let since = waitingSince[run.id] ?? Date()
        waitingSince[run.id] = since
        guard let automation = automations.first(where: { $0.id == run.automationId }),
              Date().timeIntervalSince(since) > automation.stallTimeout,
              let agentId = run.agentId
        else { return }

        await runner.stop(agentId: agentId)
        var stalled = run
        stalled.outcome = .stalled
        stalled.finishedAt = Date()
        waitingSince[run.id] = nil
        await settle(stalled)
    }

    /// Records the terminal state, decides whether the worktree earned its keep, and notifies.
    private func settle(_ run: AutomationRun) async {
        var run = run
        guard let automation = automations.first(where: { $0.id == run.automationId }) else {
            await runStore.record(run)
            return
        }

        if let worktree = run.worktreeName, let cwd = run.cwd {
            let holdsWork = await runner.worktreeHoldsWork(at: cwd)
            run.holdsWorktree = holdsWork
            if !holdsWork, let agentId = run.agentId {
                // A run that changed nothing leaves nothing behind — this is what keeps
                // fresh-worktree-per-run from becoming thirty directories a month.
                await runner.remove(agentId: agentId)
                Self.log.info("reaped \(worktree, privacy: .public): no commits, clean tree")
            }
        }
        await runStore.record(run)
        notify(automation, run: run)
        await pruneIfWanted(automation)
    }

    /// Auto-prune is off by default: a retained worktree holds work by definition, and `claude rm`
    /// takes its branch too. When the user has asked for it, the oldest beyond the limit goes.
    private func pruneIfWanted(_ automation: Automation) async {
        guard automation.autoPrune else { return }
        let retained = await runStore.retainedWorktrees(for: automation.id)
        guard retained.count > automation.keepRuns else { return }
        for run in retained.prefix(retained.count - automation.keepRuns) {
            guard let agentId = run.agentId else { continue }
            await runner.remove(agentId: agentId)
            await runStore.update(runId: run.id) { $0.holdsWorktree = false }
        }
    }

    private func notify(_ automation: Automation, run: AutomationRun) {
        guard automation.notifyOn.shouldNotify(run.outcome) else { return }
        let body: String
        let kind: NotificationStore.Entry.Kind
        switch run.outcome {
        case .finished: body = "Automation finished"; kind = .finished
        case .failed: body = "Automation failed"; kind = .error
        case .stalled: body = "Automation stopped after waiting for you"; kind = .error
        case .launchFailed(let message): body = "Automation could not start — \(message.prefix(120))"; kind = .error
        case .skipped(let reason): body = reason.title; kind = .finished
        case .running: return
        }
        router?(run.sessionId, automation.name, body, kind)
    }

    // MARK: - Hook binding

    /// `--bg` refuses `--session-id`, so a run has no identity until the CLI gives it one. The short
    /// id printed at launch is the session UUID's first eight characters, which makes this a
    /// deterministic prefix match rather than a guess bounded by a time window.
    func handle(hookEvent event: HookEvent) {
        guard event.hookEventName == "SessionStart" else { return }
        Task {
            guard let run = await runStore.run(matchingSessionId: event.sessionId), run.sessionId == nil else { return }
            await runStore.update(runId: run.id) { $0.sessionId = event.sessionId }
            await refreshRuns()
        }
    }

    // MARK: - Editing

    func add(_ automation: Automation) {
        automations.append(automation)
        persist()
        selectedId = automation.id
        armTimer()
    }

    func update(_ automation: Automation) {
        guard let i = automations.firstIndex(where: { $0.id == automation.id }) else { return }
        automations[i] = automation
        persist()
        armTimer()
    }

    func setEnabled(_ automation: Automation, _ enabled: Bool) {
        guard let i = automations.firstIndex(where: { $0.id == automation.id }) else { return }
        automations[i].isEnabled = enabled
        persist()
        armTimer()
    }

    func delete(_ automation: Automation) {
        automations.removeAll { $0.id == automation.id }
        if selectedId == automation.id { selectedId = nil }
        persist()
        armTimer()
        Task {
            // Runs still holding a worktree are left alone deliberately: deleting the schedule must
            // not silently delete work. They stay visible under `claude agents` either way.
            await runStore.forget(automationId: automation.id)
            await refreshRuns()
        }
    }

    func duplicate(_ automation: Automation) {
        var copy = automation
        copy.id = UUID()
        copy.name = automation.name + " copy"
        copy.createdAt = Date()
        copy.lastFiredAt = nil
        add(copy)
    }

    private func persist() {
        let snapshot = automations
        sessions?.update { $0.automations = snapshot }
    }

    private func refreshRuns() async {
        var out: [UUID: [AutomationRun]] = [:]
        for automation in automations { out[automation.id] = await runStore.runs(for: automation.id) }
        runs = out
    }

    // MARK: - Run actions

    func runs(for automation: Automation) -> [AutomationRun] { runs[automation.id] ?? [] }

    func confirmRemoval(of run: AutomationRun, automation: Automation) {
        guard let agentId = run.agentId else { return }
        pendingRemoval = PendingRemoval(run: run, automationName: automation.name,
                                        command: "claude rm \(agentId)")
    }

    func commitPendingRemoval() {
        guard let pending = pendingRemoval, let agentId = pending.run.agentId else { return }
        pendingRemoval = nil
        Task {
            await runner.remove(agentId: agentId)
            await runStore.update(runId: pending.run.id) { $0.holdsWorktree = false }
            await refreshRuns()
        }
    }

    func stopRun(_ run: AutomationRun) {
        guard let agentId = run.agentId else { return }
        Task {
            await runner.stop(agentId: agentId)
            await runStore.update(runId: run.id) {
                $0.outcome = .stalled
                $0.finishedAt = Date()
            }
            await refreshRuns()
        }
    }

    func flush() async { await runStore.flush() }
}
