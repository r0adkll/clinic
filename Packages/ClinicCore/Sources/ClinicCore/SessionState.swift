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
    public var toolName: String?
    public var permissionMode: String?
    public var model: String?             // PostModelSwitch (field name best-effort)
    public var stopHookActive: Bool?
    public var receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name", sessionId = "session_id", transcriptPath = "transcript_path", cwd, source
        case notificationType = "notification_type", message, toolName = "tool_name", permissionMode = "permission_mode"
        case model = "new_model", stopHookActive = "stop_hook_active", receivedAt = "_clinic_received_at"
    }

    public init(hookEventName: String, sessionId: SessionID, transcriptPath: String? = nil, cwd: String? = nil, source: String? = nil,
                notificationType: String? = nil, message: String? = nil, toolName: String? = nil, permissionMode: String? = nil,
                model: String? = nil, stopHookActive: Bool? = nil, receivedAt: Date = Date()) {
        self.hookEventName = hookEventName; self.sessionId = sessionId; self.transcriptPath = transcriptPath; self.cwd = cwd
        self.source = source; self.notificationType = notificationType; self.message = message; self.toolName = toolName
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
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        stopHookActive = try c.decodeIfPresent(Bool.self, forKey: .stopHookActive)
        receivedAt = try c.decodeIfPresent(Date.self, forKey: .receivedAt) ?? Date()
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

    /// The working→idle edge that sets `unread` and fires "finished" notifications (ADR-033).
    public static func isFinishedEdge(from old: SessionState, to new: SessionState) -> Bool {
        old == .working && new == .idle
    }
}
