import Foundation

/// Thin wrapper over the `claude plugin` CLI (ADR-084), shaped like `GitHubService`.
///
/// This is the *only* way Clinic changes anything under `~/.claude`: it never writes those files
/// itself, it hands argv to the tool that owns them ([[ADR-018]] as amended by ADR-084). Every
/// mutation is user-initiated and shown in full before it runs, which is why `displayCommand` is
/// part of the public surface rather than a debugging aid.
public actor PluginService {
    public enum Scope: String, Sendable, CaseIterable { case user, project, local }

    /// What to run. `arguments(for:)` is static so the argv is a unit test, not a live CLI call.
    public enum Operation: Equatable, Sendable {
        case list
        case marketplaces
        case install(String, Scope)
        case uninstall(String, Scope)
        case enable(String)
        case disable(String)
        case update(String, Scope)
        case marketplaceAdd(String)
        case marketplaceRemove(String)
        /// nil updates every marketplace.
        case marketplaceUpdate(String?)
    }

    public static func arguments(for op: Operation) -> [String] {
        switch op {
        case .list: ["plugin", "list", "--json", "--available"]
        case .marketplaces: ["plugin", "marketplace", "list", "--json"]
        // `install`, `uninstall` and `update` refuse to run without -y when stdout is not a TTY.
        case .install(let id, let scope): ["plugin", "install", id, "--scope", scope.rawValue, "-y"]
        case .uninstall(let id, let scope): ["plugin", "uninstall", id, "--scope", scope.rawValue, "-y"]
        // enable/disable auto-detect the scope they installed into, and take no -y.
        case .enable(let id): ["plugin", "enable", id]
        case .disable(let id): ["plugin", "disable", id]
        case .update(let id, let scope): ["plugin", "update", id, "--scope", scope.rawValue, "-y"]
        // The marketplace subcommands prompt for nothing and reject -y.
        case .marketplaceAdd(let source): ["plugin", "marketplace", "add", source]
        case .marketplaceRemove(let name): ["plugin", "marketplace", "remove", name]
        case .marketplaceUpdate(let name): ["plugin", "marketplace", "update"] + (name.map { [$0] } ?? [])
        }
    }

    /// The line shown in the confirmation sheet before a mutation runs.
    public static func displayCommand(_ op: Operation, executable: String = "claude") -> String {
        ([executable] + arguments(for: op)).joined(separator: " ")
    }

    private let executable: String
    private var availability: (value: Bool, checkedAt: Date)?
    private static let availabilityTTL: TimeInterval = 60

    public init(executable: String = "claude") { self.executable = executable }

    /// `claude plugin marketplace list --json` exits 0 — which also proves the CLI is new enough to
    /// have `plugin` at all. Cached for 60 s, like `GitHubService.isAvailable()`.
    public func isAvailable() async -> Bool {
        if let availability, Date().timeIntervalSince(availability.checkedAt) < Self.availabilityTTL { return availability.value }
        let ok = await run(.marketplaces).status == 0
        availability = (ok, Date())
        return ok
    }

    // MARK: Reads

    public func catalog() async throws -> [PluginEntry] {
        let list = PluginCatalog.parseList(try await claude(.list).stdout)
        let refs = try await marketplaces()
        let local = PluginCatalog.loadLocalMetadata(marketplaces: refs)
        return PluginCatalog.merge(list: list, manifests: local.manifests, cache: local.cache, blocklist: local.blocklist)
    }

    public func marketplaces() async throws -> [MarketplaceRef] {
        let cli = PluginCatalog.parseMarketplaces(try await claude(.marketplaces).stdout)
        return PluginCatalog.merge(marketplaces: cli, known: PluginCatalog.loadKnownMarketplaces())
    }

    // MARK: Mutations — each one a command the user confirmed

    public func perform(_ op: Operation) async throws {
        _ = try await claude(op)
    }

    // MARK: Process plumbing

    @discardableResult
    private func claude(_ op: Operation) async throws -> ToolProcess.Result {
        let r = await run(op)
        guard r.status == 0 else { throw PluginError(command: Self.displayCommand(op, executable: executable), exitCode: r.status, output: r.stderr, stdout: r.stdoutString) }
        return r
    }

    private func run(_ op: Operation) async -> ToolProcess.Result {
        var env = ProcessEnvironment.withToolPaths()
        // Clinic may itself have been launched from a Claude Code session; those variables would
        // otherwise leak into the child (same reason `BackgroundAgentsCLI` strips them).
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT" {
            env[key] = nil
        }
        env["NO_COLOR"] = "1"
        env["CI"] = "1"
        return await ToolProcess.run(executable: executable, arguments: Self.arguments(for: op), environment: env)
    }
}

/// A failed `claude plugin` invocation. The CLI writes its own diagnostics to stderr and exits 1;
/// they are shown verbatim rather than paraphrased, so the user reads what the tool actually said.
public struct PluginError: Error, CustomStringConvertible, Sendable {
    public var command: String
    public var exitCode: Int32
    public var output: String
    public var stdout: String

    public init(command: String, exitCode: Int32, output: String, stdout: String = "") {
        self.command = command; self.exitCode = exitCode; self.output = output; self.stdout = stdout
    }

    /// stderr if it said anything, else stdout, else a bare exit code — with ANSI and the CLI's ✘ removed.
    public var message: String {
        for candidate in [output, stdout] {
            let text = Self.plain(candidate)
            if !text.isEmpty { return text }
        }
        return "\(command) failed (exit \(exitCode))"
    }

    public var description: String { message }

    /// Strips ANSI SGR sequences and the leading status glyph the CLI prints.
    public static func plain(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        for glyph in ["✘", "✗", "×", "⚠"] where out.hasPrefix(glyph) {
            out = String(out.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}
