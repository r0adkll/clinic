import Foundation

/// A saved prompt, a schedule, and where to run it (ADR-095).
///
/// An automation does not have an execution model of its own: it fires `claude --bg`, so the run it
/// produces *is* a background agent ([[ADR-061]]) and inherits the state machine, the sidebar row,
/// attention, notifications and the transcript that Clinic already has.
public struct Automation: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var prompt: String
    public var target: Target
    public var schedule: CronSchedule
    public var isEnabled: Bool
    public var model: String?
    public var effort: String?
    public var permissionMode: PermissionMode
    public var catchUp: CatchUpPolicy
    public var notifyOn: NotifyPolicy
    /// How long a run may sit at `needs_input` before Clinic stops it. A job that needs you at 3 a.m.
    /// has already failed; the alternative is a session waiting until morning holding a worktree.
    public var stallTimeout: TimeInterval
    /// Runs whose worktree held work, kept before the oldest is offered for removal.
    public var keepRuns: Int
    /// Remove the oldest retained run automatically instead of offering it. Off by default: its
    /// worktree has work in it by definition, and `claude rm` takes the branch with it.
    public var autoPrune: Bool
    /// The template this was created from, for provenance in the UI. Nil for a blank automation.
    public var templateId: String?
    public var createdAt: Date
    /// The scheduled time this last fired *for* — not the wall clock at launch — so catch-up can tell
    /// which fires were missed without drifting.
    public var lastFiredAt: Date?

    public enum Target: Codable, Sendable, Hashable {
        /// Runs in a project directory.
        case project(path: String)
        /// Runs in Clinic's shared scratch directory, the Chats group's home ([[ADR-068]]), for
        /// automations that answer a question rather than touch a repository.
        case chat
    }

    /// What an unattended run is allowed to do. `bypassPermissions` is deliberately never a default
    /// and never inherited from a template (ADR-095).
    public enum PermissionMode: String, Codable, Sendable, Hashable, CaseIterable {
        case plan, acceptEdits, bypassPermissions

        /// The CLI value for `--permission-mode`.
        public var cliValue: String { rawValue }

        public var title: String {
            switch self {
            case .plan: "Read-only"
            case .acceptEdits: "Can edit files"
            case .bypassPermissions: "Skip all permission checks"
            }
        }

        public var detail: String {
            switch self {
            case .plan: "Reads and reports. Cannot write, so it cannot stall on a permission prompt."
            case .acceptEdits: "Accepts file edits without asking. Other tools can still prompt."
            case .bypassPermissions: "Asks for nothing at all. Choose this only for a job you trust completely."
            }
        }

        /// Isolation follows the posture: a run that cannot write has nothing to isolate, and a run
        /// that can gets a fresh worktree so it never collides with what you are doing in the repo.
        public var wantsWorktree: Bool { self != .plan }
    }

    /// What to do about fires that came due while Clinic was closed.
    public enum CatchUpPolicy: String, Codable, Sendable, Hashable, CaseIterable {
        /// One run, however many were missed. A weekend of missed hourly fires is one run, not 48.
        case runOnce
        case skip

        public var title: String {
            switch self {
            case .runOnce: "Run once on return"
            case .skip: "Skip missed runs"
            }
        }
    }

    public enum NotifyPolicy: String, Codable, Sendable, Hashable, CaseIterable {
        case everyRun, problemsOnly, never

        public var title: String {
            switch self {
            case .everyRun: "Every run"
            case .problemsOnly: "Failures and stalls only"
            case .never: "Never"
            }
        }

        public func shouldNotify(_ outcome: AutomationRun.Outcome) -> Bool {
            switch self {
            case .never: false
            case .everyRun: true
            case .problemsOnly: !outcome.isSuccess
            }
        }
    }

    public static let defaultStallTimeout: TimeInterval = 30 * 60

    public init(id: UUID = UUID(), name: String, prompt: String, target: Target, schedule: CronSchedule,
                isEnabled: Bool = true, model: String? = nil, effort: String? = nil,
                permissionMode: PermissionMode = .plan, catchUp: CatchUpPolicy = .runOnce,
                notifyOn: NotifyPolicy = .problemsOnly, stallTimeout: TimeInterval = defaultStallTimeout,
                keepRuns: Int = 5, autoPrune: Bool = false, templateId: String? = nil,
                createdAt: Date = Date(), lastFiredAt: Date? = nil) {
        self.id = id; self.name = name; self.prompt = prompt; self.target = target
        self.schedule = schedule; self.isEnabled = isEnabled; self.model = model; self.effort = effort
        self.permissionMode = permissionMode; self.catchUp = catchUp; self.notifyOn = notifyOn
        self.stallTimeout = stallTimeout; self.keepRuns = keepRuns; self.autoPrune = autoPrune
        self.templateId = templateId; self.createdAt = createdAt; self.lastFiredAt = lastFiredAt
    }

    /// Where the run's `cwd` will be. Chats resolve against the same shared scratch directory the
    /// Chats group uses, so trust is answered once (ADR-068).
    public func workingDirectory(chatsDirectory: String) -> String {
        switch target {
        case .project(let path): path
        case .chat: chatsDirectory
        }
    }

    public var projectPath: String? {
        if case .project(let path) = target { return path }
        return nil
    }

    /// A fresh worktree name per run, unique by the fire time so two runs never collide.
    /// `claude -w <name>` names both the worktree and its branch after this.
    public func worktreeName(for fireDate: Date) -> String? {
        guard permissionMode.wantsWorktree, projectPath != nil else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "auto-\(Self.slug(name))-\(f.string(from: fireDate))"
    }

    /// The `-n` display name a run carries, so the sidebar row says which automation produced it.
    public func runName(for fireDate: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "\(name) · \(f.string(from: fireDate))"
    }

    static func slug(_ s: String) -> String {
        let mapped = s.lowercased().map { ch -> Character in
            (ch.isLetter && ch.isASCII) || ch.isNumber ? ch : "-"
        }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String(collapsed.prefix(24))
    }
}

/// One firing of an automation, and what became of it (ADR-095).
public struct AutomationRun: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var automationId: UUID
    /// The scheduled time this run is *for*. May be earlier than `startedAt` on a catch-up.
    public var scheduledFor: Date
    public var startedAt: Date
    public var finishedAt: Date?
    /// The short id `claude --bg` printed, which `claude attach/logs/stop/rm` take.
    public var agentId: String?
    /// Learned from the `SessionStart` hook, since `--bg` will not accept a pre-assigned id.
    public var sessionId: SessionID?
    public var outcome: Outcome
    public var worktreeName: String?
    /// True while the run's worktree still exists — it held commits or a dirty tree, so it was not
    /// reaped on completion.
    public var holdsWorktree: Bool
    public var cwd: String?

    public enum Outcome: Codable, Sendable, Hashable {
        case running
        case finished
        case failed
        /// Stopped by Clinic after sitting at `needs_input` past the automation's stall timeout.
        case stalled
        /// Never launched. The reason is shown in the run history rather than swallowed.
        case skipped(reason: SkipReason)
        case launchFailed(message: String)

        public var isSuccess: Bool { self == .finished }
        public var isTerminal: Bool { self != .running }

        public var title: String {
            switch self {
            case .running: "Running"
            case .finished: "Finished"
            case .failed: "Failed"
            case .stalled: "Stalled"
            case .skipped(let reason): reason.title
            case .launchFailed: "Could not start"
            }
        }
    }

    public enum SkipReason: String, Codable, Sendable, Hashable {
        /// The previous run of this automation was still working. Fires do not stack (ADR-095).
        case alreadyRunning
        /// Came due while Clinic was closed, and the automation's catch-up policy is `skip`.
        case missedWhileClosed
        case disabled
        case projectMissing

        public var title: String {
            switch self {
            case .alreadyRunning: "Skipped — previous run still going"
            case .missedWhileClosed: "Missed while Clinic was closed"
            case .disabled: "Skipped — disabled"
            case .projectMissing: "Skipped — project folder is gone"
            }
        }
    }

    public init(id: UUID = UUID(), automationId: UUID, scheduledFor: Date, startedAt: Date = Date(),
                finishedAt: Date? = nil, agentId: String? = nil, sessionId: SessionID? = nil,
                outcome: Outcome = .running, worktreeName: String? = nil, holdsWorktree: Bool = false,
                cwd: String? = nil) {
        self.id = id; self.automationId = automationId; self.scheduledFor = scheduledFor
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.agentId = agentId
        self.sessionId = sessionId; self.outcome = outcome; self.worktreeName = worktreeName
        self.holdsWorktree = holdsWorktree; self.cwd = cwd
    }

    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}
