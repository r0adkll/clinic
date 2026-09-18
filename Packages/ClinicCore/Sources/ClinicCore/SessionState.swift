import Foundation

/// Session lifecycle for a tab open in Clinic (ADR-026).
public enum SessionState: String, Codable, Sendable, Hashable {
    case launching, idle, working, waitingForPermission, waitingForInput, exited

    public var isWaiting: Bool { self == .waitingForPermission || self == .waitingForInput }
}

/// A decoded hook payload delivered by clinic-hook (ADR-015, ADR-027).
public struct HookEvent: Codable, Sendable, Hashable {
    public var hookEventName: String
    public var sessionId: SessionID
    public var transcriptPath: String?
    public var cwd: String?
    public var source: String?            // SessionStart: startup | resume | clear | compact | fork
    /// SessionEnd: clear | resume | logout | prompt_input_exit | other. `clear` is not an exit (ADR-166).
    public var reason: String?
    /// Present only when the hook fired inside a subagent.
    public var agentId: String?
    public var notificationType: String?  // Notification
    public var message: String?
    /// UserPromptSubmit: the text the user submitted. Labels a turn snapshot (ADR-080).
    public var prompt: String?
    public var toolName: String?
    public var permissionMode: String?
    public var model: String?             // PostModelSwitch (field name best-effort)
    public var stopHookActive: Bool?
    /// Set on the `StatusLine` pseudo-event: the CLI's status line input, forwarded by `clinic-hook statusline` (ADR-157).
    public var statusLine: StatusLineReport?
    public var receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name", sessionId = "session_id", transcriptPath = "transcript_path", cwd, source
        case reason, agentId = "agent_id"
        case notificationType = "notification_type", message, prompt, toolName = "tool_name", permissionMode = "permission_mode"
        case model = "new_model", stopHookActive = "stop_hook_active", receivedAt = "_clinic_received_at"
        case statusLine = "_clinic_status_line"
    }

    public init(hookEventName: String, sessionId: SessionID, transcriptPath: String? = nil, cwd: String? = nil, source: String? = nil,
                reason: String? = nil, agentId: String? = nil, notificationType: String? = nil, message: String? = nil, prompt: String? = nil, toolName: String? = nil, permissionMode: String? = nil,
                model: String? = nil, stopHookActive: Bool? = nil, receivedAt: Date = Date()) {
        self.hookEventName = hookEventName; self.sessionId = sessionId; self.transcriptPath = transcriptPath; self.cwd = cwd
        self.source = source; self.reason = reason; self.agentId = agentId; self.notificationType = notificationType; self.message = message; self.prompt = prompt; self.toolName = toolName
        self.permissionMode = permissionMode; self.model = model; self.stopHookActive = stopHookActive; self.receivedAt = receivedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hookEventName = try c.decode(String.self, forKey: .hookEventName)
        sessionId = try c.decode(SessionID.self, forKey: .sessionId)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId)
        notificationType = try c.decodeIfPresent(String.self, forKey: .notificationType)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        stopHookActive = try c.decodeIfPresent(Bool.self, forKey: .stopHookActive)
        receivedAt = try c.decodeIfPresent(Date.self, forKey: .receivedAt) ?? Date()
        // The status line input is a document of its own shape, not a hook payload, so it is read from
        // the top level rather than from a key.
        statusLine = hookEventName == StatusLineReport.eventName ? try? StatusLineReport(from: decoder) : nil
    }

    /// Decodes a raw hook JSON payload. Unknown fields are ignored.
    public static func decode(_ data: Data) throws -> HookEvent {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(HookEvent.self, from: data)
    }
}

/// Pure transition function. Returns the new state, or nil if the event does not change state.
public enum SessionStateMachine {
    public static let waitingNotificationTypes: Set<String> = ["idle_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"]

    public static func reduce(_ state: SessionState, event: HookEvent) -> SessionState? {
        switch event.hookEventName {
        case "SessionStart":
            // Compaction restarts the session record in the middle of a turn: an automatic one is
            // followed by more work and a `Stop`, a manual one began at the prompt. Neither moves the
            // state (ADR-166, verified against 2.1.276).
            return event.source == "compact" ? nil : .idle
        case "UserPromptSubmit":
            return .working
        case "PermissionRequest":
            return .waitingForPermission
        case "PreToolUse", "PermissionDenied":
            return state == .waitingForPermission ? .working : nil
        case "Notification":
            if let t = event.notificationType {
                if t == "permission_prompt" { return .waitingForPermission }
                if waitingNotificationTypes.contains(t) { return state == .exited ? nil : .waitingForInput }
            }
            return nil
        case "Stop", "StopFailure":
            return .idle
        case "SessionEnd":
            // `/clear` ends the session id, not the process: a `SessionStart` with a new id follows
            // within milliseconds and the tab is re-keyed to it (ADR-166).
            return event.reason == "clear" ? nil : .exited
        default:
            return nil
        }
    }

    /// The notification type a `waitingForInput` session is waiting on, carried across a transition.
    /// A later `idle_prompt` does not replace a dialog's type: the dialog is still what is on screen.
    public static func waitingOn(_ current: String?, from old: SessionState, to new: SessionState, event: HookEvent) -> String? {
        guard new == .waitingForInput else { return nil }
        guard event.hookEventName == "Notification", let type = event.notificationType else { return current }
        return old == .waitingForInput && type == "idle_prompt" ? current : type
    }

    /// Claude is at its own prompt, so a typed line becomes the next prompt. That is `idle`, and also
    /// `waitingForInput` on `idle_prompt`, which the CLI sends after ~60 s at the prompt (and which is the
    /// only event that ends an interrupted turn). A dialog also reads `waitingForInput`, but a line typed
    /// there answers the dialog.
    public static func acceptsPrompt(_ state: SessionState?, waitingOn: String?) -> Bool {
        state == .idle || (state == .waitingForInput && waitingOn == "idle_prompt")
    }

    /// The working→idle edge that sets `unread` and fires "finished" notifications (ADR-033).
    public static func isFinishedEdge(from old: SessionState, to new: SessionState) -> Bool {
        old == .working && new == .idle
    }
}

/// What the terminal itself says about a session, judged against the state the hooks built (ADR-166).
///
/// Hooks are delivered by a helper process per event and some endings fire none at all: an interrupt,
/// and a permission dialog dismissed with Esc (verified against 2.1.276). The CLI's own terminal output
/// is in-band and ordered, so it is the second witness:
/// - **OSC 9;4** is sent once when a turn starts (`indeterminate`) and once when it is over (`remove`).
///   It stays set through a permission dialog and, per the CLI's docs, while background subagents run.
/// - **The title** starts with `✳` at rest *and* while a dialog blocks the turn, and with a spinner
///   glyph while the turn is moving. It is the only signal that a permission was granted: `PreToolUse`
///   arrives before `PermissionRequest`, so no hook follows the approval until the tool has finished.
public enum TerminalWitness {
    /// A quiet report has to outlast this before it ends a turn. A `Stop` hook normally lands within
    /// milliseconds and wins; Collins measured the CLI clearing the report briefly between tool calls.
    public static let quietGrace: TimeInterval = 3
    /// A busy report has to outlast this before it starts one. `/exit` and other local commands set the
    /// report for a fraction of a second, and a turn that short is not worth a "finished" notification.
    public static let busyGrace: TimeInterval = 1.5

    public enum Verdict: Sendable, Hashable {
        /// Re-check after the delay and move to `state` if `stillHolds` says the evidence stands.
        case after(TimeInterval, SessionState)
        /// The report contradicts nothing; drop any verdict still pending.
        case settle
    }

    /// - Parameter sawBusy: whether this terminal has ever reported busy. A CLI that never emits OSC 9;4
    ///   (the setting off, an old version) sends a `remove` at startup and nothing else, so a quiet
    ///   report only counts from a terminal that has shown it reports both edges.
    public static func progress(busy: Bool, sawBusy: Bool, state: SessionState, waitingOn: String?) -> Verdict {
        if busy {
            return SessionStateMachine.acceptsPrompt(state, waitingOn: waitingOn) ? .after(busyGrace, .working) : .settle
        }
        guard sawBusy else { return .settle }
        return state == .working || state == .waitingForPermission ? .after(quietGrace, .idle) : .settle
    }

    /// Whether a pending verdict should still be applied once its delay has run out.
    public static func stillHolds(_ target: SessionState, busy: Bool, state: SessionState, waitingOn: String?) -> Bool {
        switch target {
        case .working: return busy && SessionStateMachine.acceptsPrompt(state, waitingOn: waitingOn)
        case .idle: return !busy && (state == .working || state == .waitingForPermission)
        default: return false
        }
    }

    public enum TitleActivity: Sendable { case moving, resting }

    /// The glyph the CLI prefixes its title with. Braille frames are what it drew before 2.1.228.
    public static func titleActivity(_ title: String) -> TitleActivity? {
        guard let first = title.unicodeScalars.first else { return nil }
        switch first.value {
        case 0x2733: return .resting                       // ✳
        case 0x25D0...0x25D3, 0x2800...0x28FF: return .moving   // ◐◑◒◓, braille
        default: return nil
        }
    }

    /// A moving title while the state says "needs permission" means the dialog was answered.
    public static func title(_ title: String, state: SessionState) -> SessionState? {
        state == .waitingForPermission && titleActivity(title) == .moving ? .working : nil
    }

    /// A turn the transcript says is over (`SessionActivity.lastTurnEnd`) ends a state that began before
    /// it. The margin keeps the *previous* turn's closing record, which can be written in the same few
    /// milliseconds as a queued prompt's `UserPromptSubmit`, from ending the turn that prompt started.
    public static func transcriptEndsTurn(lastTurnEnd: Date?, state: SessionState, since: Date) -> Bool {
        guard let lastTurnEnd, state == .working || state == .waitingForPermission else { return false }
        return lastTurnEnd.timeIntervalSince(since) > 0.5
    }
}

/// What Claude Code hands its `statusLine` command on stdin, reduced to what Clinic shows (ADR-157).
///
/// The shape is documented inside the CLI (2.1.273) as the status line's input: `context_window` carries
/// a pre-calculated `used_percentage` and the model's `context_window_size`, which the transcript never
/// states. Every field is optional; a CLI that drops one leaves Clinic on the transcript's token count.
public struct StatusLineReport: Codable, Sendable, Hashable {
    /// The `hook_event_name` `clinic-hook statusline` stamps on the payload so it can ride the hook socket.
    public static let eventName = "StatusLine"

    /// 0–100, nil before the first message.
    public var contextUsedPercentage: Double?
    public var contextWindowSize: Int?
    public var contextTokens: Int?
    /// "Opus 5".
    public var modelDisplayName: String?
    public var modelId: String?
    /// The live effort level, which `/effort` changes without a hook.
    public var effort: String?
    /// The plan's 5-hour and 7-day windows (ADR-162). The CLI reads them off its own API responses' headers
    /// and sends a window only while its reset is still ahead; per-model weekly limits are never here.
    public var fiveHour: RateWindow?
    public var sevenDay: RateWindow?

    /// One plan window as the status line states it.
    public struct RateWindow: Sendable, Hashable {
        /// 0–100, above 100 once exceeded.
        public var usedPercentage: Double
        public var resetsAt: Date

        public init(usedPercentage: Double, resetsAt: Date) { self.usedPercentage = usedPercentage; self.resetsAt = resetsAt }
    }

    public init(contextUsedPercentage: Double? = nil, contextWindowSize: Int? = nil, contextTokens: Int? = nil,
                modelDisplayName: String? = nil, modelId: String? = nil, effort: String? = nil,
                fiveHour: RateWindow? = nil, sevenDay: RateWindow? = nil) {
        self.contextUsedPercentage = contextUsedPercentage; self.contextWindowSize = contextWindowSize
        self.contextTokens = contextTokens; self.modelDisplayName = modelDisplayName; self.modelId = modelId; self.effort = effort
        self.fiveHour = fiveHour; self.sevenDay = sevenDay
    }

    private enum Keys: String, CodingKey { case contextWindow = "context_window", model, effort, rateLimits = "rate_limits" }
    private enum RateLimitKeys: String, CodingKey { case fiveHour = "five_hour", sevenDay = "seven_day" }
    private enum WindowKeys: String, CodingKey { case usedPercentage = "used_percentage", resetsAt = "resets_at" }
    private enum ContextKeys: String, CodingKey {
        case usedPercentage = "used_percentage", contextWindowSize = "context_window_size", totalInputTokens = "total_input_tokens"
    }
    private enum ModelKeys: String, CodingKey { case id, displayName = "display_name" }
    private enum EffortKeys: String, CodingKey { case level }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let w = try? c.nestedContainer(keyedBy: ContextKeys.self, forKey: .contextWindow) {
            contextUsedPercentage = try? w.decodeIfPresent(Double.self, forKey: .usedPercentage)
            contextWindowSize = try? w.decodeIfPresent(Int.self, forKey: .contextWindowSize)
            contextTokens = try? w.decodeIfPresent(Int.self, forKey: .totalInputTokens)
        }
        if let m = try? c.nestedContainer(keyedBy: ModelKeys.self, forKey: .model) {
            modelId = try? m.decodeIfPresent(String.self, forKey: .id)
            modelDisplayName = try? m.decodeIfPresent(String.self, forKey: .displayName)
        }
        if let e = try? c.nestedContainer(keyedBy: EffortKeys.self, forKey: .effort) {
            effort = try? e.decodeIfPresent(String.self, forKey: .level)
        }
        if let r = try? c.nestedContainer(keyedBy: RateLimitKeys.self, forKey: .rateLimits) {
            fiveHour = Self.window(in: r, forKey: .fiveHour)
            sevenDay = Self.window(in: r, forKey: .sevenDay)
        }
    }

    /// `resets_at` is epoch seconds; a value too large for that is taken as milliseconds.
    private static func window(in c: KeyedDecodingContainer<RateLimitKeys>, forKey key: RateLimitKeys) -> RateWindow? {
        guard let w = try? c.nestedContainer(keyedBy: WindowKeys.self, forKey: key),
              let used = try? w.decode(Double.self, forKey: .usedPercentage),
              let resets = try? w.decode(Double.self, forKey: .resetsAt) else { return nil }
        return RateWindow(usedPercentage: used, resetsAt: Date(timeIntervalSince1970: resets > 1e10 ? resets / 1000 : resets))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        var w = c.nestedContainer(keyedBy: ContextKeys.self, forKey: .contextWindow)
        try w.encodeIfPresent(contextUsedPercentage, forKey: .usedPercentage)
        try w.encodeIfPresent(contextWindowSize, forKey: .contextWindowSize)
        try w.encodeIfPresent(contextTokens, forKey: .totalInputTokens)
        var m = c.nestedContainer(keyedBy: ModelKeys.self, forKey: .model)
        try m.encodeIfPresent(modelId, forKey: .id)
        try m.encodeIfPresent(modelDisplayName, forKey: .displayName)
        if let effort {
            var e = c.nestedContainer(keyedBy: EffortKeys.self, forKey: .effort)
            try e.encode(effort, forKey: .level)
        }
        if fiveHour != nil || sevenDay != nil {
            var r = c.nestedContainer(keyedBy: RateLimitKeys.self, forKey: .rateLimits)
            for (key, window) in [(RateLimitKeys.fiveHour, fiveHour), (.sevenDay, sevenDay)] {
                guard let window else { continue }
                var w = r.nestedContainer(keyedBy: WindowKeys.self, forKey: key)
                try w.encode(window.usedPercentage, forKey: .usedPercentage)
                try w.encode(window.resetsAt.timeIntervalSince1970, forKey: .resetsAt)
            }
        }
    }
}
