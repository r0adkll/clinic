import Foundation

/// Thin wrapper over the `gh` CLI (ADR-053). Every call shells out off the main actor; a non-zero exit throws `GitHubError`.
/// Nothing here touches GitHub directly, so the user's existing `gh auth` is the only credential.
public actor GitHubService {
    public enum MergeMethod: String, Sendable, CaseIterable { case merge, squash, rebase }

    /// Fields requested from `gh pr view --json`; `PullRequest.parse` understands exactly these.
    public static let viewFields: [String] = [
        "number", "title", "body", "state", "isDraft", "url", "author", "headRefName", "baseRefName", "createdAt", "updatedAt",
        "mergedAt", "mergeable", "mergeStateStatus", "reviewDecision", "autoMergeRequest", "additions", "deletions",
        "changedFiles", "statusCheckRollup", "comments", "reviews",
    ]
    static let checksFields = ["name", "state", "link", "workflow", "startedAt", "completedAt"]

    /// What to run; `arguments(for:)` turns it into a `gh` argv (kept static so tests can cover it without `gh`).
    enum Operation: Equatable {
        case authStatus
        case viewer
        case view(PullRequestRef)
        case diff(PullRequestRef)
        case ready(PullRequestRef)
        case merge(PullRequestRef, MergeMethod, auto: Bool)
        case disableAutoMerge(PullRequestRef)
        case checks(PullRequestRef)
    }

    static func arguments(for op: Operation) -> [String] {
        switch op {
        case .authStatus: ["auth", "status"]
        case .viewer: ["api", "user", "--jq", ".login"]
        case .view(let ref): ["pr", "view", ref.url.absoluteString, "--json", viewFields.joined(separator: ",")]
        case .diff(let ref): ["pr", "diff", ref.url.absoluteString]
        case .ready(let ref): ["pr", "ready", ref.url.absoluteString]
        case .merge(let ref, let method, let auto): ["pr", "merge", ref.url.absoluteString, "--\(method.rawValue)"] + (auto ? ["--auto"] : [])
        case .disableAutoMerge(let ref): ["pr", "merge", ref.url.absoluteString, "--disable-auto"]
        case .checks(let ref): ["pr", "checks", ref.url.absoluteString, "--json", checksFields.joined(separator: ",")]
        }
    }

    private let executable: String
    private var availability: (value: Bool, checkedAt: Date)?
    private var cachedViewer: String?
    private static let availabilityTTL: TimeInterval = 60

    public init(executable: String = "gh") { self.executable = executable }

    /// `gh` on PATH and `gh auth status` exits 0. Cached for 60 s.
    public func isAvailable() async -> Bool {
        if let availability, Date().timeIntervalSince(availability.checkedAt) < Self.availabilityTTL { return availability.value }
        let ok = await run(.authStatus).status == 0
        availability = (ok, Date())
        return ok
    }

    /// `gh api user --jq .login`, cached for the lifetime of the service.
    public func viewerLogin() async -> String? {
        if let cachedViewer { return cachedViewer }
        let r = await run(.viewer)
        guard r.status == 0 else { return nil }
        let login = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { return nil }
        cachedViewer = login
        return login
    }

    /// `gh pr view <url> --json <viewFields>`.
    public func pullRequest(_ ref: PullRequestRef) async throws -> PullRequest {
        let r = try await gh(.view(ref))
        return try PullRequest.parse(r.stdout, ref: ref)
    }

    /// `gh pr diff <url>`.
    public func diff(_ ref: PullRequestRef) async throws -> UnifiedDiff {
        UnifiedDiff.parse(try await gh(.diff(ref)).stdoutString)
    }

    /// `gh pr ready <url>`.
    public func markReady(_ ref: PullRequestRef) async throws {
        _ = try await gh(.ready(ref))
    }

    /// `gh pr merge <url> --<method> [--auto]`.
    public func merge(_ ref: PullRequestRef, method: MergeMethod, auto: Bool) async throws {
        _ = try await gh(.merge(ref, method, auto: auto))
    }

    /// `gh pr merge <url> --disable-auto`.
    public func disableAutoMerge(_ ref: PullRequestRef) async throws {
        _ = try await gh(.disableAutoMerge(ref))
    }

    /// `gh pr checks <url> --json …`. Older `gh` releases lack `--json` here; those fall back to the rollup from `pullRequest()`.
    public func checks(_ ref: PullRequestRef) async throws -> [PullRequest.Check] {
        let r = await run(.checks(ref))
        if r.status == 0 { return try PullRequest.parseChecksList(r.stdout) }
        if r.stderr.contains("unknown flag") || r.stderr.contains("--json") {
            return try await pullRequest(ref).checks
        }
        // `gh pr checks` also exits non-zero for "no checks reported" on some versions; treat that as empty.
        if r.stderr.localizedCaseInsensitiveContains("no checks reported") { return [] }
        throw r.error(Self.arguments(for: .checks(ref)))
    }

    // MARK: Process plumbing

    @discardableResult
    private func gh(_ op: Operation) async throws -> GitHubProcess.Result {
        let r = await run(op)
        guard r.status == 0 else { throw r.error(Self.arguments(for: op)) }
        return r
    }

    private func run(_ op: Operation) async -> GitHubProcess.Result {
        await GitHubProcess.run(executable: executable, Self.arguments(for: op))
    }
}

/// A failed `gh` invocation.
public struct GitHubError: Error, CustomStringConvertible, Sendable {
    public var command: String
    public var exitCode: Int32
    public var stderr: String
    public var description: String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "gh \(command) failed (exit \(exitCode))" : "gh \(command) failed (exit \(exitCode)): \(trimmed)"
    }
    public init(command: String, exitCode: Int32, stderr: String) {
        self.command = command; self.exitCode = exitCode; self.stderr = stderr
    }
}

/// Runs `/usr/bin/env gh …` with prompts, colour, and update nags disabled.
enum GitHubProcess {
    typealias Result = ToolProcess.Result

    static func run(executable: String, _ args: [String]) async -> Result {
        var env = ProcessEnvironment.withToolPaths()
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        env["LANG"] = "C"
        env["LC_ALL"] = "C"
        env["GH_PAGER"] = "cat"
        env["PAGER"] = "cat"
        return await ToolProcess.run(executable: executable, arguments: args, environment: env)
    }
}

extension ToolProcess.Result {
    func error(_ args: [String]) -> GitHubError { GitHubError(command: args.joined(separator: " "), exitCode: status, stderr: stderr) }
}
