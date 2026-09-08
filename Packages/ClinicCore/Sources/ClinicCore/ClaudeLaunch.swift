import Foundation

/// Builds the command typed into the shell (ADR-016, ADR-017, ADR-032).
public struct ClaudeLaunch: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case new(id: SessionID)
        case resume(id: SessionID, fork: Bool)
        /// Re-attach to a session running detached (ADR-061).
        case attach(agentId: String)
    }

    public var mode: Mode
    public var model: String?
    public var effort: String?
    public var worktree: Bool
    public var settingsFilePath: String
    public var executable: String = "claude"
    /// First turn, passed as the CLI's positional prompt.
    public var prompt: String?
    /// Per-session MCP config file (ADR-056).
    public var mcpConfigPath: String?

    public init(mode: Mode, model: String? = nil, effort: String? = nil, worktree: Bool = false, settingsFilePath: String, executable: String = "claude", prompt: String? = nil) {
        self.mode = mode; self.model = model; self.effort = effort; self.worktree = worktree; self.settingsFilePath = settingsFilePath; self.executable = executable; self.prompt = prompt
    }

    public var arguments: [String] {
        var args: [String] = []
        switch mode {
        case .new(let id):
            args += ["--session-id", id.rawValue]
        case .resume(let id, let fork):
            args += ["--resume", id.rawValue]
            if fork { args.append("--fork-session") }
        case .attach(let agentId):
            // `claude attach <id>` takes no other options.
            return ["attach", agentId]
        }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let effort, !effort.isEmpty { args += ["--effort", effort] }
        if worktree, case .new = mode { args.append("-w") }
        args += ["--settings", settingsFilePath]
        if let mcpConfigPath, !mcpConfigPath.isEmpty { args += ["--mcp-config", mcpConfigPath] }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty { args.append(prompt) }
        return args
    }

    /// Shell-quoted line, newline-terminated, suitable for libghostty `initial_input`.
    public var shellLine: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ") + "\n"
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@,"))
        if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Generates the `--settings` JSON that registers Clinic's hooks (ADR-027).
public enum HookSettings {
    public static let events: [String] = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PermissionDenied", "Notification",
        "Stop", "StopFailure", "PostModelSwitch", "CwdChanged", "WorktreeCreate", "SessionEnd",
    ]

    /// - Parameters:
    ///   - helperPath: absolute path to the bundled `clinic-hook` executable.
    ///   - socketPath: Clinic's Unix socket; passed as an argument so the helper needs no discovery.
    public static func json(helperPath: String, socketPath: String) throws -> Data {
        let hook: [String: Any] = [
            "type": "command",
            "command": [helperPath, socketPath].map(ClaudeLaunch.shellQuote).joined(separator: " "),
            "async": true,
            "timeout": 5,
        ]
        var hooks: [String: Any] = [:]
        for event in events { hooks[event] = [["hooks": [hook]]] }
        let root: [String: Any] = ["hooks": hooks]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }
}
