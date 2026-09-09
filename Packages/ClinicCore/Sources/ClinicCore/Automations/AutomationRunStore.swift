import Foundation

/// Run history, in its own file beside `state.json` (ADR-095).
///
/// [[ADR-021 Persistence]] put Clinic's state in one small JSON document and noted that anything
/// which grows without bound belongs elsewhere. Run history is exactly that: a nightly automation
/// produces a record a day forever, and those records must never make the file that holds the sidebar
/// slower to read.
///
/// Two retentions live here and they are not the same thing:
/// - **History rows** are capped per automation, so the detail pane has something to show without the
///   file growing for ever.
/// - **Worktrees** are governed by `Automation.keepRuns`, because a retained worktree holds real work
///   and dropping its history row would lose the only handle on it. A run holding a worktree is
///   therefore never trimmed by the history cap.
public actor AutomationRunStore {
    private let url: URL
    private var byAutomation: [UUID: [AutomationRun]]
    private var pendingWrite: Task<Void, Never>?
    private let debounce: Duration
    /// How many finished runs to keep per automation for display.
    public static let historyLimit = 20

    public init(url: URL, debounce: Duration = .milliseconds(500)) {
        self.url = url
        self.debounce = debounce
        self.byAutomation = (try? Self.load(from: url)) ?? [:]
    }

    public static func defaultURL(appSupport: URL = ClinicPaths.appSupport) -> URL {
        appSupport.appendingPathComponent("Clinic", isDirectory: true)
            .appendingPathComponent("automation-runs.json")
    }

    // MARK: - Reads

    /// Newest first, which is the order the detail pane shows them in.
    public func runs(for automationId: UUID) -> [AutomationRun] {
        (byAutomation[automationId] ?? []).sorted { $0.startedAt > $1.startedAt }
    }

    public func lastRun(for automationId: UUID) -> AutomationRun? { runs(for: automationId).first }

    /// The run still occupying an agent slot, if any. Fires do not stack: this is what a due fire
    /// checks before launching.
    public func activeRun(for automationId: UUID) -> AutomationRun? {
        runs(for: automationId).first { $0.outcome == .running }
    }

    public func allRunning() -> [AutomationRun] {
        byAutomation.values.flatMap { $0 }.filter { $0.outcome == .running }
    }

    /// Runs whose worktree survived because it held commits or a dirty tree, oldest first — the order
    /// they come up for removal in.
    public func retainedWorktrees(for automationId: UUID) -> [AutomationRun] {
        (byAutomation[automationId] ?? []).filter(\.holdsWorktree).sorted { $0.startedAt < $1.startedAt }
    }

    /// The run a `SessionStart` belongs to, matched on the short id the CLI printed.
    public func run(matchingSessionId sessionId: SessionID) -> AutomationRun? {
        byAutomation.values.flatMap { $0 }.first { run in
            if run.sessionId == sessionId { return true }
            guard run.sessionId == nil, let agentId = run.agentId else { return false }
            return AutomationLauncher.sessionId(sessionId, matches: agentId)
        }
    }

    // MARK: - Writes

    /// Insert or replace by run id.
    public func record(_ run: AutomationRun) {
        var list = byAutomation[run.automationId] ?? []
        if let i = list.firstIndex(where: { $0.id == run.id }) { list[i] = run } else { list.append(run) }
        byAutomation[run.automationId] = trim(list)
        schedule()
    }

    @discardableResult
    public func update(runId: UUID, _ mutate: @Sendable (inout AutomationRun) -> Void) -> AutomationRun? {
        for (automationId, var list) in byAutomation {
            guard let i = list.firstIndex(where: { $0.id == runId }) else { continue }
            mutate(&list[i])
            let updated = list[i]
            byAutomation[automationId] = trim(list)
            schedule()
            return updated
        }
        return nil
    }

    /// Drops an automation's history wholesale, for when the automation itself is deleted.
    public func forget(automationId: UUID) {
        byAutomation[automationId] = nil
        schedule()
    }

    /// A run holding a worktree is never trimmed away: the history row is the only handle on the
    /// worktree, and losing it would leave an orphan directory with no way back to it from the UI.
    private func trim(_ list: [AutomationRun]) -> [AutomationRun] {
        guard list.count > Self.historyLimit else { return list }
        let sorted = list.sorted { $0.startedAt > $1.startedAt }
        var kept: [AutomationRun] = []
        for run in sorted where kept.count < Self.historyLimit || run.holdsWorktree || run.outcome == .running {
            kept.append(run)
        }
        return kept.sorted { $0.startedAt < $1.startedAt }
    }

    public func flush() async {
        pendingWrite?.cancel()
        pendingWrite = nil
        try? Self.write(byAutomation, to: url)
    }

    private func schedule() {
        pendingWrite?.cancel()
        pendingWrite = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.flushNow()
        }
    }

    private func flushNow() { try? Self.write(byAutomation, to: url) }

    static func load(from url: URL) throws -> [UUID: [AutomationRun]] {
        let data = try Data(contentsOf: url)
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode([UUID: [AutomationRun]].self, from: data)
    }

    static func write(_ runs: [UUID: [AutomationRun]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(runs).write(to: url, options: .atomic)
    }
}
