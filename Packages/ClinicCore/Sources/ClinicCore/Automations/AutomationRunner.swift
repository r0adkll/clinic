import Foundation

/// Runs an automation's fire, and cleans up after it (ADR-095).
///
/// Shaped like `MCPService` and `PluginService`: an actor over the CLI, with the argv it builds
/// living in `AutomationLauncher` so it stays a unit test. This is the only part of the feature that
/// touches a process.
public actor AutomationRunner {
    private let executable: String

    public init(executable: String = "claude") { self.executable = executable }

    public struct LaunchOutcome: Sendable, Equatable {
        /// The short id `claude attach/logs/stop/rm` take. Nil when the launch failed, or succeeded
        /// but printed something this build does not recognise.
        public var agentId: String?
        public var status: Int32
        public var output: String
        public var isSuccess: Bool { status == 0 && agentId != nil }
    }

    /// Fires `claude --bg` in `directory` and reads the short id back out of stdout.
    ///
    /// Returns as soon as the CLI does — a second or so — because `--bg` detaches. Everything after
    /// this point reaches Clinic through the hooks the launch registered, not through this process.
    public func launch(_ launch: ClaudeLaunch, in directory: String) async -> LaunchOutcome {
        let result = await ToolProcess.run(executable: executable,
                                           arguments: launch.arguments,
                                           environment: Self.environment(),
                                           currentDirectory: URL(fileURLWithPath: directory))
        let combined = result.stdoutString + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
        return LaunchOutcome(agentId: AutomationLauncher.parseAgentId(combined),
                             status: result.status,
                             output: combined.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `claude stop <id>` — ends the session but leaves its job state and worktree.
    @discardableResult
    public func stop(agentId: String) async -> Bool {
        await ToolProcess.run(executable: executable, arguments: ["stop", agentId],
                              environment: Self.environment()).status == 0
    }

    /// `claude rm <id>` — the reaper.
    ///
    /// Verified against the real CLI: this removes the resident process's job state **and the run's
    /// worktree and branch**, which `claude stop` itself points at
    /// (`run 'claude rm <id>' to remove worktree and job state`). It is therefore the whole retention
    /// mechanism, and also why removing a run that holds work is always confirmed rather than
    /// automatic.
    @discardableResult
    public func remove(agentId: String) async -> Bool {
        await ToolProcess.run(executable: executable, arguments: ["rm", agentId],
                              environment: Self.environment()).status == 0
    }

    /// Whether a run's worktree is worth keeping: any uncommitted change, or any commit that is not
    /// on the base branch.
    ///
    /// This is the test behind "a run that changed nothing leaves nothing behind" — the thing that
    /// stops a fresh-worktree-per-run automation becoming thirty directories a month. When the answer
    /// cannot be determined the worktree is **kept**: deleting work because git was unreadable would
    /// be much worse than leaving a directory behind.
    public func worktreeHoldsWork(at path: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }

        let dirty = await GitProcess.run(["status", "--porcelain", "--untracked-files=all"], in: path)
        guard dirty.status == 0 else { return true }
        if !dirty.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }

        // Commits the worktree's branch has that its upstream/base does not. `@{upstream}` is absent
        // for a branch the CLI just created, so fall back to the merge-base with the default branch.
        let ahead = await GitProcess.run(["rev-list", "--count", "@{upstream}..HEAD"], in: path)
        if ahead.status == 0 {
            return (Int(ahead.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
        }
        for base in ["main", "master"] {
            let r = await GitProcess.run(["rev-list", "--count", "\(base)..HEAD"], in: path)
            if r.status == 0 {
                return (Int(r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
            }
        }
        return true
    }

    /// Scrubbed the same way `PluginService` and `MCPService` scrub, so a `claude` launched from
    /// inside a Claude Code session does not inherit that session's identity.
    static func environment() -> [String: String] {
        var env = ProcessEnvironment.withToolPaths()
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_")
            || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT" {
            env[key] = nil
        }
        return env
    }
}
