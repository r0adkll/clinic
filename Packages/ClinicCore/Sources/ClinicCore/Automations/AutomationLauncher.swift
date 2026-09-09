import Foundation

/// Turns an automation into argv, and reads back the id the CLI prints (ADR-095).
///
/// Both halves are pure so the launch is a unit test rather than a live `claude --bg` call — the same
/// reason `MCPService.arguments(for:)` and `PluginService` are shaped this way.
public enum AutomationLauncher {
    /// The launch for one firing.
    ///
    /// Deliberately *not* `.new(id:)`: `--bg` refuses `--session-id`, so the run has no identity until
    /// the CLI gives it one. `parseAgentId` reads the short id from stdout and `SessionStart` supplies
    /// the full UUID, which the short id is a prefix of.
    public static func launch(for automation: Automation, fireDate: Date, settingsFilePath: String,
                              mcpConfigPath: String? = nil, executable: String = "claude") -> ClaudeLaunch {
        let worktreeName = automation.worktreeName(for: fireDate)
        var launch = ClaudeLaunch(mode: .background(name: automation.runName(for: fireDate)),
                                  model: automation.model,
                                  effort: automation.effort,
                                  worktree: worktreeName != nil,
                                  settingsFilePath: settingsFilePath,
                                  executable: executable,
                                  prompt: automation.prompt)
        launch.worktreeName = worktreeName
        launch.mcpConfigPath = mcpConfigPath
        launch.permissionMode = automation.permissionMode.cliValue
        return launch
    }

    /// The short id out of `--bg`'s stdout, which looks like:
    ///
    /// ```
    /// Starting background service…
    /// backgrounded · e6f9d349 · Morning triage · 9 Sep 2026 at 08:30
    ///   claude agents             list sessions
    /// ```
    ///
    /// The id is taken from the `backgrounded` line rather than by scanning for anything hex-shaped,
    /// because the run's *name* is on that line too and a name can contain a hex-looking word.
    public static func parseAgentId(_ output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("backgrounded") else { continue }
            // Separator is U+00B7; split on it and take the field after "backgrounded".
            let fields = trimmed.split(separator: "\u{00B7}").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { continue }
            let candidate = fields[1]
            if isShortId(candidate) { return candidate }
        }
        return nil
    }

    static func isShortId(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 36 && s.allSatisfy { $0.isHexDigit || $0 == "-" } && s.contains(where: \.isHexDigit)
    }

    /// Whether a `SessionStart` id belongs to a run launched with this short id.
    ///
    /// The CLI prints the first eight characters of the session UUID, so this is a prefix test rather
    /// than a guess bounded by a time window — verified against the real CLI: `e6f9d349` for
    /// `e6f9d349-dc80-4619-9704-9f75cf2ef4a0`.
    public static func sessionId(_ sessionId: SessionID, matches shortId: String) -> Bool {
        let full = sessionId.rawValue.lowercased()
        let short = shortId.lowercased()
        guard !short.isEmpty else { return false }
        return full == short || full.hasPrefix(short)
    }
}
