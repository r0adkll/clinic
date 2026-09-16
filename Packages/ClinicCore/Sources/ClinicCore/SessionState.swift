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
        case notificationType = "notification_type", message, prompt, toolName = "tool_name", permissionMode = "permission_mode"
        case model = "new_model", stopHookActive = "stop_hook_active", receivedAt = "_clinic_received_at"
        case statusLine = "_clinic_status_line"
    }

    public init(hookEventName: String, sessionId: SessionID, transcriptPath: String? = nil, cwd: String? = nil, source: String? = nil,
                notificationType: String? = nil, message: String? = nil, prompt: String? = nil, toolName: String? = nil, permissionMode: String? = nil,
                model: String? = nil, stopHookActive: Bool? = nil, receivedAt: Date = Date()) {
        self.hookEventName = hookEventName; self.sessionId = sessionId; self.transcriptPath = transcriptPath; self.cwd = cwd
        self.source = source; self.notificationType = notificationType; self.message = message; self.prompt = prompt; self.toolName = toolName
        self.permissionMode = permissionMode; self.model = model; self.stopHookActive = stopHookActive; self.receivedAt = receivedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hookEventName = try c.decode(String.self, forKey: .hookEventName)
        sessionId = try c.decode(SessionID.self, forKey: .sessionId)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        source = try c.decodeIfPresent(String.self, forKey: .source)
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
            return .idle
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
            return .exited
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
