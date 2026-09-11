import Foundation

/// GitHub as a work-item provider (ADR-113): a thin adapter over the one `GitHubService` actor, so
/// issues share its availability cache, viewer logins and process plumbing with pull requests.
public struct GitHubWorkItemProvider: WorkItemProvider {
    public static let kind = "github"
    public var kind: String { Self.kind }
    public let service: GitHubService

    public init(service: GitHubService) { self.service = service }

    public func availability() async -> ToolAvailability { await service.availability() }
    public func viewerLogin(host: String) async -> String? { await service.viewerLogin(host: host) }
    public func resolveSources(projectPath: String) async -> WorkItemSourceResolution {
        await service.resolveRepository(projectPath: projectPath)
    }
    public func list(_ source: WorkItemSource, state: WorkItemState, limit: Int) async throws -> WorkItemPage {
        try await service.issues(source, state: state, limit: limit)
    }
    public func mentioningViewer(host: String) async throws -> [WorkItemRef] { try await service.mentionedIssues(host: host) }
    public func detail(_ ref: WorkItemRef) async throws -> WorkItemDetail { try await service.issueDetail(ref) }
    public func sessionPrompt(for item: WorkItem) -> String { Self.prompt(for: item) }

    /// A reference, not the body (ADR-114): Claude reads the issue fresh, comments included. Named by
    /// URL so a source override can never make `gh` resolve the number against the wrong repository.
    public static func prompt(for item: WorkItem) -> String {
        let url = item.ref.url.absoluteString
        return """
        Work on GitHub issue \(item.ref.display): "\(item.title)"
        \(url)

        Start by reading it with `gh issue view \(url) --comments`.
        """
    }
}

/// Pure parsers for the issue operations' output (ADR-113). Like `PullRequest.parse`, hand-written
/// over `JSONSerialization` so a field GitHub adds or drops degrades instead of failing the page.
public enum GitHubIssues {
    /// `gh repo view --json nameWithOwner,url`.
    public static func parseRepoView(_ data: Data) -> WorkItemSource? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let scope = obj["nameWithOwner"] as? String, scope.contains("/") else { return nil }
        let host = (obj["url"] as? String).flatMap(URL.init(string:))?.host ?? "github.com"
        return .github(scope, host: host)
    }

    /// `gh repo view`'s refusals, shortened to what the scope column can say on hover (ADR-112).
    public static func unresolvedReason(_ stderr: String) -> String {
        let s = stderr.lowercased()
        if s.contains("not a git repository") { return "Not a git repository" }
        if s.contains("no git remotes") { return "No git remote" }
        if s.contains("none of the git remotes") || s.contains("known github host") { return "No GitHub remote gh knows" }
        if s.contains("could not resolve to a repository") { return "Repository not found on GitHub" }
        let line = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { String($0.prefix(160)) } ?? "gh could not resolve a repository"
    }

    public struct IssuesPage: Equatable, Sendable {
        public var items: [WorkItem]
        public var nextCursor: String?
    }

    /// One page of `GitHubService.issuesQuery`.
    public static func parseIssuesPage(_ data: Data, source: WorkItemSource) throws -> IssuesPage {
        let repo = try repository(data)
        guard let issues = repo["issues"] as? [String: Any] else {
            throw GitHubError(command: "api graphql", exitCode: 0, stderr: "unexpected GraphQL shape (no issues)")
        }
        let info = issues["pageInfo"] as? [String: Any]
        let next = (info?["hasNextPage"] as? Bool == true) ? info?["endCursor"] as? String : nil
        let items = (issues["nodes"] as? [[String: Any]] ?? []).compactMap { item(from: $0, source: source) }
        return IssuesPage(items: items, nextCursor: next)
    }

    static func item(from n: [String: Any], source: WorkItemSource) -> WorkItem? {
        guard let number = (n["number"] as? NSNumber)?.intValue,
              let url = (n["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let created = PullRequest.date(n["createdAt"]) ?? Date(timeIntervalSince1970: 0)
        let labels = ((n["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { l -> WorkItemLabel? in
            guard let name = l["name"] as? String else { return nil }
            return WorkItemLabel(name: name, color: (l["color"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        let assignees = ((n["assignees"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }
        return WorkItem(
            ref: WorkItemRef(source: source, number: number, url: url),
            title: n["title"] as? String ?? "",
            body: n["body"] as? String ?? "",
            state: (n["state"] as? String)?.uppercased() == "CLOSED" ? .closed : .open,
            stateReason: (n["stateReason"] as? String)?.lowercased(),
            author: login(n["author"]),
            assignees: assignees,
            labels: labels,
            milestone: (n["milestone"] as? [String: Any])?["title"] as? String,
            commentCount: ((n["comments"] as? [String: Any])?["totalCount"] as? NSNumber)?.intValue ?? 0,
            createdAt: created,
            updatedAt: PullRequest.date(n["updatedAt"]) ?? created,
            closedAt: PullRequest.date(n["closedAt"]))
    }

    /// `gh search issues --json url,number,repository`.
    public static func parseMentions(_ data: Data, host: String) throws -> [WorkItemRef] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError(command: "search issues", exitCode: 0, stderr: "unexpected JSON shape (expected an array)")
        }
        return items.compactMap { i in
            guard let number = (i["number"] as? NSNumber)?.intValue,
                  let url = (i["url"] as? String).flatMap(URL.init(string:)),
                  let scope = (i["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
            return WorkItemRef(source: .github(scope, host: host), number: number, url: url)
        }
    }

    /// `GitHubService.issueDetailQuery`.
    public static func parseDetail(_ data: Data, ref: WorkItemRef, now: Date = Date()) throws -> WorkItemDetail {
        guard let issue = try repository(data)["issue"] as? [String: Any] else {
            throw GitHubError(command: "api graphql", exitCode: 0, stderr: "unexpected GraphQL shape (no issue)")
        }
        let commentsObj = issue["comments"] as? [String: Any]
        let comments = (commentsObj?["nodes"] as? [[String: Any]] ?? []).compactMap { c -> WorkItemDetail.Comment? in
            guard let id = c["id"] as? String else { return nil }
            let author = c["author"] as? [String: Any]
            return WorkItemDetail.Comment(id: id, author: login(author),
                                          avatarURL: (author?["avatarUrl"] as? String).flatMap(URL.init(string:)),
                                          createdAt: PullRequest.date(c["createdAt"]) ?? now,
                                          bodyHTML: c["bodyHTML"] as? String ?? "",
                                          url: (c["url"] as? String).flatMap(URL.init(string:)))
        }
        let prs = ((issue["closedByPullRequestsReferences"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { p -> WorkItemDetail.LinkedPullRequest? in
            guard let number = (p["number"] as? NSNumber)?.intValue, let url = (p["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let state: PullRequest.State = switch (p["state"] as? String ?? "").uppercased() {
            case "MERGED": .merged
            case "CLOSED": .closed
            default: .open
            }
            return WorkItemDetail.LinkedPullRequest(number: number, title: p["title"] as? String ?? "", url: url,
                                                    state: state, isDraft: p["isDraft"] as? Bool ?? false)
        }
        return WorkItemDetail(ref: ref, bodyHTML: issue["bodyHTML"] as? String,
                              authorAvatarURL: ((issue["author"] as? [String: Any])?["avatarUrl"] as? String).flatMap(URL.init(string:)),
                              comments: comments, totalComments: (commentsObj?["totalCount"] as? NSNumber)?.intValue,
                              linkedPullRequests: prs, fetchedAt: now)
    }

    /// `data.repository`, or the first GraphQL error as a `GitHubError`.
    private static func repository(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError(command: "api graphql", exitCode: 0, stderr: "unexpected JSON shape (expected an object)")
        }
        if let repo = (obj["data"] as? [String: Any])?["repository"] as? [String: Any] { return repo }
        let message = ((obj["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? "unexpected GraphQL shape (no repository)"
        throw GitHubError(command: "api graphql", exitCode: 0, stderr: message)
    }

    /// A deleted account comes back as a null author; GitHub shows it as `ghost`, and so does Clinic.
    private static func login(_ raw: Any?) -> String {
        guard let a = raw as? [String: Any], let login = a["login"] as? String, !login.isEmpty else { return "ghost" }
        return login
    }
}
