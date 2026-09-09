import Foundation

/// Thin wrapper over the `claude mcp` CLI (ADR-093), shaped like `PluginService`.
///
/// As with plugins, this is the *only* way Clinic changes MCP configuration: it never writes
/// `~/.claude.json` or a `.mcp.json` itself, it hands argv to the tool that owns them
/// ([[ADR-018]] as amended by ADR-084 and ADR-093).
///
/// Two shapes are forced on us by the CLI and worth stating here rather than discovering downstream:
/// - **`add` refuses to overwrite** an existing name, so there is no edit — only remove-then-add,
///   which `MCPServersModel` drives with a rollback.
/// - **`--scope local` and `--scope project` act on whichever project the process is standing in**,
///   so every mutation carries a working directory rather than a project argument.
public actor MCPService {
    /// What to run. `arguments(for:)` is static so the argv is a unit test, not a live CLI call.
    public enum Operation: Equatable, Sendable {
        /// Always `add-json`: one code path for the form and for a pasted snippet, and no
        /// `-e`/`-H`/`--` argv assembly to get subtly wrong.
        case add(name: String, definition: MCPServerDefinition, scope: MCPScope)
        case remove(name: String, scope: MCPScope)
        case get(name: String)
        case login(name: String)
        case logout(name: String)
        case importFromClaudeDesktop(scope: MCPScope)
        case resetProjectChoices
    }

    public static func arguments(for op: Operation) -> [String] {
        switch op {
        case .add(let name, let definition, let scope):
            ["mcp", "add-json", name, definition.json, "--scope", scope.rawValue]
        case .remove(let name, let scope):
            ["mcp", "remove", name, "--scope", scope.rawValue]
        case .get(let name):
            ["mcp", "get", name]
        case .login(let name):
            ["mcp", "login", name]
        case .logout(let name):
            ["mcp", "logout", name]
        case .importFromClaudeDesktop(let scope):
            ["mcp", "add-from-claude-desktop", "--scope", scope.rawValue]
        case .resetProjectChoices:
            ["mcp", "reset-project-choices"]
        }
    }

    /// The line shown to the user before a mutation runs.
    ///
    /// A deliberate, named deviation from ADR-084's "shown in full": an `add` carries the server's
    /// env values and headers, and printing an API key in full would be worse than printing it
    /// masked. The redaction is **display only** — the real value still goes through argv, and then
    /// into `~/.claude.json` in plaintext, which the screen says out loud (ADR-093).
    public static func displayCommand(_ op: Operation, executable: String = "claude") -> String {
        var argv = arguments(for: op)
        if case .add(_, let definition, _) = op, let i = argv.firstIndex(of: definition.json) {
            argv[i] = "'" + definition.redactedJSON + "'"
        }
        return ([executable] + argv).joined(separator: " ")
    }

    private let executable: String
    private var availability: (value: Bool, checkedAt: Date)?
    private static let availabilityTTL: TimeInterval = 60

    public init(executable: String = "claude") { self.executable = executable }

    /// `claude mcp get` on a name that cannot exist: exits 1 with "No MCP server named …", which still
    /// proves the CLI is present and has an `mcp` subcommand. A missing binary exits -1 instead.
    public func isAvailable() async -> Bool {
        if let availability, Date().timeIntervalSince(availability.checkedAt) < Self.availabilityTTL { return availability.value }
        let r = await run(.get(name: "clinic-availability-probe"), in: nil)
        let ok = r.status >= 0 && !r.stderr.contains("could not launch")
        availability = (ok, Date())
        return ok
    }

    // MARK: Mutations — each one a command the user confirmed

    public func perform(_ op: Operation, in projectPath: String? = nil) async throws {
        let r = await run(op, in: projectPath)
        guard r.status == 0 else {
            throw MCPError(command: Self.displayCommand(op, executable: executable),
                           exitCode: r.status, output: r.stderr, stdout: r.stdoutString)
        }
    }

    // MARK: Status

    /// `claude mcp get <name>`, reduced to a health verdict.
    ///
    /// Only the `Status:` and `Issue:` lines are kept. The rest of that output contains the server's
    /// env values and headers in plaintext, which Clinic has no business holding (ADR-093).
    public func health(name: String, in projectPath: String?) async -> MCPHealth {
        let r = await run(.get(name: name), in: projectPath)
        guard r.status == 0 else { return .unknown }
        return Self.parseHealth(r.stdoutString)
    }

    public static func parseHealth(_ output: String) -> MCPHealth {
        var status: String?
        var issue: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Status:") { status = String(t.dropFirst("Status:".count)).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("Issue:") { issue = String(t.dropFirst("Issue:".count)).trimmingCharacters(in: .whitespaces) }
        }
        guard let status else { return .unknown }
        let lower = status.lowercased()
        if lower.contains("connected") { return .connected }
        if lower.contains("needs authentication") { return .needsAuthentication }
        if lower.contains("pending approval") { return .pendingApproval }
        if lower.contains("failed") || lower.contains("error") {
            // A failing HTTP server can return an entire HTML page as its issue; keep a sentence.
            return .failed(issue.map { String($0.prefix(200)) } ?? status)
        }
        return .unknown
    }

    // MARK: Process plumbing

    private func run(_ op: Operation, in projectPath: String?) async -> ToolProcess.Result {
        var env = ProcessEnvironment.withToolPaths()
        // Clinic may itself have been launched from a Claude Code session; those variables would
        // otherwise leak into the child (same reason `PluginService` strips them).
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT" {
            env[key] = nil
        }
        env["NO_COLOR"] = "1"
        env["CI"] = "1"
        return await ToolProcess.run(executable: executable, arguments: Self.arguments(for: op), environment: env,
                                     currentDirectory: projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }
}

/// What `claude mcp get` says about a server right now.
public enum MCPHealth: Sendable, Hashable {
    case connected
    case needsAuthentication
    case pendingApproval
    case failed(String)
    case unknown

    public var label: String {
        switch self {
        case .connected: "Connected"
        case .needsAuthentication: "Needs authentication"
        case .pendingApproval: "Pending approval"
        case .failed: "Failed to connect"
        case .unknown: "Unknown"
        }
    }

    public var detail: String? { if case .failed(let d) = self { return d } else { return nil } }
}

/// A failed `claude mcp` invocation. The CLI writes its own diagnostics and exits non-zero; they are
/// shown verbatim rather than paraphrased, so the user reads what the tool actually said.
public struct MCPError: Error, CustomStringConvertible, Sendable {
    public var command: String
    public var exitCode: Int32
    public var output: String
    public var stdout: String

    public init(command: String, exitCode: Int32, output: String, stdout: String = "") {
        self.command = command; self.exitCode = exitCode; self.output = output; self.stdout = stdout
    }

    /// stderr if it said anything, else stdout, else a bare exit code.
    ///
    /// `mcp add` and `mcp remove` report their failures on **stdout** ("MCP server demo already
    /// exists in user config"), unlike `plugin`, which is why stdout is not merely a fallback here.
    public var message: String {
        for candidate in [output, stdout] {
            let text = PluginError.plain(candidate)
            if !text.isEmpty { return text }
        }
        return "\(command) failed (exit \(exitCode))"
    }

    public var description: String { message }
}

/// Deciding what to do when a multi-step mutation fails partway (ADR-093).
///
/// Editing a server is `remove` then `add`, and `claude mcp add` refuses to overwrite — so if the
/// add fails the server is *already gone*. This is the only place in Clinic where one user action is
/// two mutations with a window between them, so the decision lives here as a pure function rather
/// than inline in a view model where it could not be tested.
public enum MCPEditRecovery {
    /// Roll back only when something actually ran and there is a snapshot to put back. A failure on
    /// the *first* step changed nothing, so restoring would add a server the user never had.
    public static func shouldRestore(completedSteps: Int, hasSnapshot: Bool) -> Bool {
        completedSteps > 0 && hasSnapshot
    }

    /// The failure text, which always leads with what the CLI said.
    public static func message(failure: String, outcome: Outcome) -> String {
        switch outcome {
        case .nothingToUndo:
            failure
        case .restored:
            "\(failure)\n\nThe original server was restored."
        case .restoreFailed(let reason, let command):
            "\(failure)\n\nRestoring the original also failed: \(reason)\nRun this yourself to put it back:\n\(command)"
        }
    }

    public enum Outcome: Equatable, Sendable {
        case nothingToUndo
        case restored
        case restoreFailed(reason: String, command: String)
    }
}
