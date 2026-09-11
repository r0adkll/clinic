import Foundation

/// Thin wrapper over the `gh` CLI (ADR-053). Every call shells out off the main actor; a non-zero exit throws `GitHubError`.
/// Nothing here touches GitHub directly, so the user's existing `gh auth` is the only credential.
public actor GitHubService {
    public enum MergeMethod: String, Sendable, CaseIterable { case merge, squash, rebase }

    /// Fields requested from `gh pr view --json`; `PullRequest.parse` understands exactly these.
    public static let viewFields: [String] = [
        "number", "title", "body", "state", "isDraft", "url", "author", "headRefName", "baseRefName", "createdAt", "updatedAt",
        "mergedAt", "mergeable", "mergeStateStatus", "reviewDecision", "autoMergeRequest", "additions", "deletions",
        "changedFiles", "statusCheckRollup", "comments", "reviews", "labels", "reviewRequests", "commits",
    ]
    static let checksFields = ["name", "state", "link", "workflow", "startedAt", "completedAt"]

    /// What to run; `arguments(for:)` turns it into a `gh` argv (kept static so tests can cover it without `gh`).
    enum Operation: Equatable {
        case authStatus
        /// Nil host = `gh`'s default host.
        case viewer(host: String?)
        case view(PullRequestRef)
        case diff(PullRequestRef)
        case ready(PullRequestRef)
        case merge(PullRequestRef, MergeMethod, auto: Bool)
        case disableAutoMerge(PullRequestRef)
        case checks(PullRequestRef)
        case bodyHTML(PullRequestRef)
        // Issues (ADR-113)
        /// `gh repo view` run *in* the project, so the answer is whatever `gh` would use there.
        case repoView(projectPath: String)
        case issues(WorkItemSource, WorkItemState, after: String?)
        case mentions(host: String, limit: Int)
        case issueDetail(WorkItemRef)
    }

    /// One GraphQL query for GitHub's own rendering of the PR body and every comment and review on
    /// it, plus each author's avatar (ADR-090, ADR-091). Node ids come back alongside so `PullRequest.applying` can match them to what
    /// `gh pr view --json` already parsed.
    static let bodyHTMLQuery = """
    query($owner:String!,$repo:String!,$number:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$number){
          bodyHTML
          author{login avatarUrl}
          comments(first:100){nodes{id bodyHTML author{login avatarUrl}}}
          reviews(first:100){nodes{id bodyHTML author{login avatarUrl}}}
        }
      }
    }
    """

    /// One page of a repository's issues, newest activity first (ADR-113). `comments { totalCount }`
    /// is the reason this is GraphQL rather than `gh issue list --json`: that command can only report
    /// a comment count by shipping up to 100 full comment bodies per issue. The state is spelled into
    /// the query because `-F` cannot pass a GraphQL list.
    static func issuesQuery(state: WorkItemState) -> String {
        """
        query($owner:String!,$repo:String!,$after:String){
          repository(owner:$owner,name:$repo){
            issues(first:100,after:$after,states:[\(state == .open ? "OPEN" : "CLOSED")],orderBy:{field:UPDATED_AT,direction:DESC}){
              pageInfo{hasNextPage endCursor}
              nodes{
                number title body url state stateReason createdAt updatedAt closedAt
                author{login}
                assignees(first:10){nodes{login}}
                labels(first:20){nodes{name color}}
                milestone{title}
                comments{totalCount}
              }
            }
          }
        }
        """
    }

    /// GitHub's rendering of one issue and its first 100 comments, plus the PRs that would close it (ADR-112).
    static let issueDetailQuery = """
    query($owner:String!,$repo:String!,$number:Int!){
      repository(owner:$owner,name:$repo){
        issue(number:$number){
          bodyHTML
          author{login avatarUrl}
          comments(first:100){totalCount nodes{id url createdAt bodyHTML author{login avatarUrl}}}
          closedByPullRequestsReferences(first:10,includeClosedPrs:true){nodes{number title url state isDraft}}
        }
      }
    }
    """

    static let repoViewFields = ["nameWithOwner", "url"]
    static let mentionFields = ["url", "number", "repository"]

    static func arguments(for op: Operation) -> [String] {
        switch op {
        case .authStatus: ["auth", "status"]
        case .viewer(let host): ["api", "user", "--jq", ".login"] + (host.map { ["--hostname", $0] } ?? [])
        case .repoView: ["repo", "view", "--json", repoViewFields.joined(separator: ",")]
        case .issues(let source, let state, let after):
            ["api", "graphql", "--hostname", source.host,
             "-F", "owner=\(source.owner)", "-F", "repo=\(source.repo)"]
            + (after.map { ["-F", "after=\($0)"] } ?? [])
            + ["-f", "query=\(issuesQuery(state: state))"]
        case .mentions(_, let limit):
            ["search", "issues", "--mentions", "@me", "--state", "open", "--limit", "\(limit)",
             "--json", mentionFields.joined(separator: ",")]
        case .issueDetail(let ref):
            ["api", "graphql", "--hostname", ref.source.host,
             "-F", "owner=\(ref.source.owner)", "-F", "repo=\(ref.source.repo)", "-F", "number=\(ref.number)",
             "-f", "query=\(issueDetailQuery)"]
        case .view(let ref): ["pr", "view", ref.url.absoluteString, "--json", viewFields.joined(separator: ",")]
        case .diff(let ref): ["pr", "diff", ref.url.absoluteString]
        case .ready(let ref): ["pr", "ready", ref.url.absoluteString]
        case .merge(let ref, let method, let auto): ["pr", "merge", ref.url.absoluteString, "--\(method.rawValue)"] + (auto ? ["--auto"] : [])
        case .disableAutoMerge(let ref): ["pr", "merge", ref.url.absoluteString, "--disable-auto"]
        case .checks(let ref): ["pr", "checks", ref.url.absoluteString, "--json", checksFields.joined(separator: ",")]
        case .bodyHTML(let ref):
            // `-F` sends number as a real Int; `-f` would make it a String and GraphQL would reject it.
            ["api", "graphql", "--hostname", ref.host,
             "-F", "owner=\(ref.owner)", "-F", "repo=\(ref.name)", "-F", "number=\(ref.number)",
             "-f", "query=\(bodyHTMLQuery)"]
        }
    }

    /// Why the PR and issue features are or are not usable (ADR-086). Every tool-backed provider
    /// shares the shape now (ADR-113); the name stays so the PR code reads as it did.
    public typealias Availability = ToolAvailability

    private let executable: String
    private var availability: (value: Availability, checkedAt: Date)?
    private var cachedViewer: String?
    private var cachedViewers: [String: String] = [:]
    private static let availabilityTTL: TimeInterval = 60

    public init(executable: String = "gh") { self.executable = executable }

    /// `gh` on PATH and `gh auth status` exits 0. Cached for 60 s.
    public func isAvailable() async -> Bool { await availability().isReady }

    /// `gh auth status`, classified. Cached for 60 s.
    public func availability() async -> Availability {
        if let availability, Date().timeIntervalSince(availability.checkedAt) < Self.availabilityTTL { return availability.value }
        let r = await run(.authStatus)
        let value = Self.classify(r, executable: executable)
        availability = (value, Date())
        if value != .ready { cachedViewer = nil; cachedViewers = [:] }
        return value
    }

    /// `/usr/bin/env` exits 127 when the tool is not on `PATH`, and `Process.run` throwing gives -1;
    /// everything else is `gh` itself objecting, which means it exists and the login is the problem.
    static func classify(_ r: GitHubProcess.Result, executable: String, path: String? = nil) -> Availability {
        if r.status == 0 { return .ready }
        let searched = path ?? ProcessEnvironment.withToolPaths()["PATH"] ?? ""
        if r.status == 127 || r.status == -1 || r.stderr.contains("\(executable): No such file or directory") {
            return .notInstalled(searchedPath: searched)
        }
        return .notAuthenticated(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `gh api user --jq .login`, cached for the lifetime of the service.
    public func viewerLogin() async -> String? {
        if let cachedViewer { return cachedViewer }
        let r = await run(.viewer(host: nil))
        guard r.status == 0 else { return nil }
        let login = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { return nil }
        cachedViewer = login
        return login
    }

    /// The signed-in login on one host (`gh api user --hostname`), cached per host. Enterprise hosts
    /// have their own account, so "Assigned to me" has to ask each one (ADR-113).
    public func viewerLogin(host: String) async -> String? {
        if let cached = cachedViewers[host] { return cached }
        let r = await run(.viewer(host: host))
        guard r.status == 0 else { return nil }
        let login = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { return nil }
        cachedViewers[host] = login
        return login
    }

    // MARK: Issues (ADR-113)

    /// The repository `gh` would use in `projectPath`: its `set-default`, else the first of
    /// `upstream`, `github`, `origin`. `gh`'s refusal is classified into a short reason.
    public func resolveRepository(projectPath: String) async -> WorkItemSourceResolution {
        let r = await run(.repoView(projectPath: projectPath))
        guard r.status == 0 else { return .unresolved(reason: GitHubIssues.unresolvedReason(r.stderr)) }
        guard let source = GitHubIssues.parseRepoView(r.stdout) else {
            return .unresolved(reason: "gh reported no repository")
        }
        return .resolved([source])
    }

    /// Issues in one state, 100 at a time, until `limit` or the last page.
    public func issues(_ source: WorkItemSource, state: WorkItemState, limit: Int) async throws -> WorkItemPage {
        var items: [WorkItem] = []
        var after: String?
        while true {
            let page = try GitHubIssues.parseIssuesPage(try await gh(.issues(source, state, after: after)).stdout, source: source)
            items += page.items
            if items.count >= limit { return WorkItemPage(items: Array(items.prefix(limit)), truncated: page.nextCursor != nil || items.count > limit) }
            guard let next = page.nextCursor else { return WorkItemPage(items: items, truncated: false) }
            after = next
        }
    }

    /// Open issues on `host` that mention the viewer (`gh search issues --mentions @me`).
    public func mentionedIssues(host: String, limit: Int = 200) async throws -> [WorkItemRef] {
        try GitHubIssues.parseMentions(try await gh(.mentions(host: host, limit: limit)).stdout, host: host)
    }

    /// GitHub's rendered body and thread for one issue, and the PRs that would close it.
    public func issueDetail(_ ref: WorkItemRef) async throws -> WorkItemDetail {
        try GitHubIssues.parseDetail(try await gh(.issueDetail(ref)).stdout, ref: ref)
    }

    /// `gh pr view <url> --json <viewFields>`.
    public func pullRequest(_ ref: PullRequestRef) async throws -> PullRequest {
        let r = try await gh(.view(ref))
        return try PullRequest.parse(r.stdout, ref: ref)
    }

    /// GitHub's rendered HTML for the body and every comment (ADR-090).
    public func renderedHTML(_ ref: PullRequestRef) async throws -> PullRequest.RenderedHTML {
        try PullRequest.parseRenderedHTML(try await gh(.bodyHTML(ref)).stdout)
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
        await GitHubProcess.run(executable: executable, Self.arguments(for: op),
                                environment: Self.environment(for: op), currentDirectory: Self.directory(for: op))
    }

    /// `gh search` has no `--hostname`; an Enterprise host is chosen the way `gh` documents, by `GH_HOST`.
    static func environment(for op: Operation) -> [String: String] {
        if case .mentions(let host, _) = op, host != "github.com" { return ["GH_HOST": host] }
        return [:]
    }

    static func directory(for op: Operation) -> URL? {
        if case .repoView(let path) = op { return URL(fileURLWithPath: path, isDirectory: true) }
        return nil
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

    static func run(executable: String, _ args: [String], environment extra: [String: String] = [:],
                    currentDirectory: URL? = nil) async -> Result {
        var env = ProcessEnvironment.withToolPaths()
        env.merge(extra) { _, new in new }
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        env["LANG"] = "C"
        env["LC_ALL"] = "C"
        env["GH_PAGER"] = "cat"
        env["PAGER"] = "cat"
        return await ToolProcess.run(executable: executable, arguments: args, environment: env, currentDirectory: currentDirectory)
    }
}

extension ToolProcess.Result {
    func error(_ args: [String]) -> GitHubError { GitHubError(command: args.joined(separator: " "), exitCode: status, stderr: stderr) }
}
