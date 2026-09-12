import Foundation

/// A GitHub pull request as reported by `gh pr view --json` (ADR-053). Pure data; `GitHubService` fetches it.
public struct PullRequest: Hashable, Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case open, merged, closed }

    public struct Author: Hashable, Codable, Sendable {
        public var login: String
        public var name: String?
        /// Filled by the same GraphQL call that fetches rendered HTML (ADR-091); `gh pr view --json`
        /// does not report it. Nil for an author that call did not cover.
        public var avatarURL: URL?
        public init(login: String, name: String? = nil, avatarURL: URL? = nil) {
            self.login = login; self.name = name; self.avatarURL = avatarURL
        }
        /// GitHub Apps (`dependabot[bot]`, and `app/dependabot` as `gh pr view` spells an App author) and
        /// the Actions bot. Used to keep bot chatter out of "unanswered comments" and to label it in the timeline.
        public var isBot: Bool {
            login.hasPrefix("app/") || login.hasSuffix("[bot]") || login == "github-actions" || login == "dependabot"
        }
        /// The login GraphQL reports for this author: `gh pr view` prefixes a GitHub App with `app/`,
        /// GraphQL does not, and the avatars from ADR-091 are keyed by GraphQL's spelling.
        var graphQLLogin: String { login.hasPrefix("app/") ? String(login.dropFirst(4)) : login }
    }

    public struct Check: Hashable, Codable, Sendable, Identifiable {
        public enum Status: String, Codable, Sendable {
            case success, failure, pending, skipped, cancelled, neutral, unknown

            /// Maps a raw GraphQL `conclusion`/`status`/`state` value (`SUCCESS`, `IN_PROGRESS`, `TIMED_OUT`, …).
            init(gh raw: String) {
                switch raw.uppercased() {
                case "SUCCESS": self = .success
                case "FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE": self = .failure
                case "PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED": self = .pending
                case "SKIPPED": self = .skipped
                case "CANCELLED", "CANCELED": self = .cancelled
                case "NEUTRAL": self = .neutral
                default: self = .unknown
                }
            }
        }
        public var id: String
        public var name: String
        public var status: Status
        public var detailsURL: URL?
        public var workflow: String?
        public var startedAt: Date?
        public var completedAt: Date?

        public init(id: String, name: String, status: Status, detailsURL: URL? = nil, workflow: String? = nil, startedAt: Date? = nil, completedAt: Date? = nil) {
            self.id = id; self.name = name; self.status = status; self.detailsURL = detailsURL
            self.workflow = workflow; self.startedAt = startedAt; self.completedAt = completedAt
        }
    }

    public struct Comment: Hashable, Codable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case comment, review, reviewComment }
        public var id: String
        public var kind: Kind
        public var author: Author
        public var body: String
        public var createdAt: Date
        public var url: URL?
        /// APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED / PENDING for reviews.
        public var reviewState: String?
        public var path: String?
        public var line: Int?
        /// GitHub's own rendering of `body`, fetched separately (ADR-090). Nil until that call lands.
        public var bodyHTML: String?

        public init(id: String, kind: Kind, author: Author, body: String, createdAt: Date, url: URL? = nil,
                    reviewState: String? = nil, path: String? = nil, line: Int? = nil, bodyHTML: String? = nil) {
            self.id = id; self.kind = kind; self.author = author; self.body = body; self.createdAt = createdAt; self.url = url
            self.reviewState = reviewState; self.path = path; self.line = line; self.bodyHTML = bodyHTML
        }
    }

    public var ref: PullRequestRef
    public var title: String
    public var body: String
    public var state: State
    public var isDraft: Bool
    public var author: Author
    public var headRefName: String
    public var baseRefName: String
    /// The head commit. A push moves it, which is the panel's signal that the diff it cached for the
    /// Files tab is of an older PR than the one on screen (ADR-127).
    public var headRefOid: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var mergedAt: Date?
    /// MERGEABLE / CONFLICTING / UNKNOWN
    public var mergeable: String
    /// CLEAN / BLOCKED / BEHIND / DIRTY / UNSTABLE / HAS_HOOKS / UNKNOWN
    public var mergeStateStatus: String
    /// APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / ""
    public var reviewDecision: String
    public var autoMergeEnabled: Bool
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var checks: [Check]
    /// Issue comments and reviews merged, chronological.
    public var comments: [Comment]
    /// In the repository's own colours, as on the Tasks screen (ADR-116).
    public var labels: [WorkItemLabel]
    /// Logins (or team names) asked to review and not yet heard from.
    public var reviewRequests: [String]
    /// Nil when `gh` did not report the commits, so the header can leave the count out rather than say 0.
    public var commitCount: Int?
    public var fetchedAt: Date
    /// GitHub's own rendering of `body` (ADR-090). Nil until `GitHubService.bodyHTML` lands, so the
    /// panel can show the Markdown source immediately and swap in the real thing when it arrives.
    public var bodyHTML: String?
    public var id: String { ref.id }

    public init(ref: PullRequestRef, title: String, body: String = "", state: State, isDraft: Bool = false, author: Author,
                headRefName: String = "", baseRefName: String = "", headRefOid: String? = nil,
                createdAt: Date, updatedAt: Date, mergedAt: Date? = nil,
                mergeable: String = "UNKNOWN", mergeStateStatus: String = "UNKNOWN", reviewDecision: String = "",
                autoMergeEnabled: Bool = false, additions: Int = 0, deletions: Int = 0, changedFiles: Int = 0,
                checks: [Check] = [], comments: [Comment] = [], labels: [WorkItemLabel] = [], reviewRequests: [String] = [],
                commitCount: Int? = nil, fetchedAt: Date = Date(), bodyHTML: String? = nil) {
        self.ref = ref; self.title = title; self.body = body; self.state = state; self.isDraft = isDraft; self.author = author
        self.headRefName = headRefName; self.baseRefName = baseRefName; self.headRefOid = headRefOid
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.mergedAt = mergedAt; self.mergeable = mergeable; self.mergeStateStatus = mergeStateStatus
        self.reviewDecision = reviewDecision; self.autoMergeEnabled = autoMergeEnabled; self.additions = additions
        self.deletions = deletions; self.changedFiles = changedFiles; self.checks = checks; self.comments = comments
        self.labels = labels; self.reviewRequests = reviewRequests; self.commitCount = commitCount
        self.fetchedAt = fetchedAt; self.bodyHTML = bodyHTML
    }

    // MARK: Reviewers

    /// Someone who reviewed this PR or was asked to, with the verdict that stands (ADR-116).
    public struct Reviewer: Hashable, Sendable, Identifiable {
        public enum Verdict: String, Hashable, Sendable { case approved, changesRequested, commented, requested }
        public var login: String
        public var avatarURL: URL?
        public var verdict: Verdict
        public var id: String { login }
    }

    /// One entry per reviewer, in the order they first reviewed, then outstanding requests.
    ///
    /// A reviewer's latest approval or request for changes is their verdict; a plain comment never
    /// overrides one, because leaving a note after approving does not withdraw the approval. A
    /// dismissed review drops them back to "commented". The author answering in review threads is
    /// not a review of their own PR, so the author is never listed.
    public var reviewers: [Reviewer] {
        var order: [String] = []
        var byLogin: [String: Reviewer] = [:]
        for c in comments where c.kind == .review && c.author.login != author.login {
            let login = c.author.login
            let previous = byLogin[login]?.verdict
            let verdict: Reviewer.Verdict
            switch c.reviewState {
            case "APPROVED": verdict = .approved
            case "CHANGES_REQUESTED": verdict = .changesRequested
            case "DISMISSED": verdict = .commented
            default: verdict = previous ?? .commented
            }
            if byLogin[login] == nil { order.append(login) }
            byLogin[login] = Reviewer(login: login, avatarURL: c.author.avatarURL ?? byLogin[login]?.avatarURL, verdict: verdict)
        }
        for login in reviewRequests where byLogin[login] == nil {
            order.append(login)
            byLogin[login] = Reviewer(login: login, avatarURL: nil, verdict: .requested)
        }
        return order.compactMap { byLogin[$0] }
    }

    /// GitHub's five-square diffstat: the squares split between additions and deletions in proportion,
    /// and a side that changed anything always gets at least one. `(0, 0)` when nothing changed.
    public static func diffstatBlocks(additions: Int, deletions: Int, total: Int = 5) -> (added: Int, deleted: Int) {
        let sum = additions + deletions
        guard sum > 0, total > 1 else { return (0, 0) }
        var added = Int((Double(additions) / Double(sum) * Double(total)).rounded())
        if additions > 0 { added = max(added, 1) }
        if deletions > 0 { added = min(added, total - 1) }
        return (added, total - added)
    }

    // MARK: Parsing

    /// Parses `gh pr view --json <GitHubService.viewFields>` output. Every field is optional except `number`; unknown shapes are skipped.
    public static func parse(_ data: Data, ref: PullRequestRef, now: Date = Date()) throws -> PullRequest {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError(command: "pr view", exitCode: 0, stderr: "unexpected JSON shape (expected an object)")
        }
        guard obj["number"] is NSNumber else {
            throw GitHubError(command: "pr view", exitCode: 0, stderr: "pull request JSON has no `number`")
        }
        let state: State
        switch (obj["state"] as? String ?? "").uppercased() {
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default: state = .open
        }
        let createdAt = date(obj["createdAt"]) ?? now
        var comments: [Comment] = []
        for c in obj["comments"] as? [[String: Any]] ?? [] {
            let body = c["body"] as? String ?? ""
            let id = c["id"] as? String ?? c["url"] as? String ?? "comment-\(comments.count)"
            comments.append(Comment(id: id, kind: .comment, author: author(c["author"]), body: body,
                                    createdAt: date(c["createdAt"]) ?? createdAt, url: url(c["url"])))
        }
        for r in obj["reviews"] as? [[String: Any]] ?? [] {
            let id = r["id"] as? String ?? r["url"] as? String ?? "review-\(comments.count)"
            comments.append(Comment(id: id, kind: .review, author: author(r["author"]), body: r["body"] as? String ?? "",
                                    createdAt: date(r["submittedAt"]) ?? date(r["createdAt"]) ?? createdAt, url: url(r["url"]),
                                    reviewState: (r["state"] as? String)?.uppercased()))
        }
        comments.sort { $0.createdAt < $1.createdAt }

        return PullRequest(
            ref: ref,
            title: obj["title"] as? String ?? "",
            body: obj["body"] as? String ?? "",
            state: state,
            isDraft: obj["isDraft"] as? Bool ?? false,
            author: author(obj["author"]),
            headRefName: obj["headRefName"] as? String ?? "",
            baseRefName: obj["baseRefName"] as? String ?? "",
            headRefOid: obj["headRefOid"] as? String,
            createdAt: createdAt,
            updatedAt: date(obj["updatedAt"]) ?? createdAt,
            mergedAt: date(obj["mergedAt"]),
            mergeable: (obj["mergeable"] as? String ?? "UNKNOWN").uppercased(),
            mergeStateStatus: (obj["mergeStateStatus"] as? String ?? "UNKNOWN").uppercased(),
            reviewDecision: (obj["reviewDecision"] as? String ?? "").uppercased(),
            autoMergeEnabled: obj["autoMergeRequest"] is [String: Any],
            additions: (obj["additions"] as? NSNumber)?.intValue ?? 0,
            deletions: (obj["deletions"] as? NSNumber)?.intValue ?? 0,
            changedFiles: (obj["changedFiles"] as? NSNumber)?.intValue ?? 0,
            checks: parseRollup(obj["statusCheckRollup"]),
            comments: comments,
            labels: (obj["labels"] as? [[String: Any]] ?? []).compactMap { l in
                (l["name"] as? String).map { WorkItemLabel(name: $0, color: l["color"] as? String) }
            },
            // A request names a `User` by login or a `Team` by name.
            reviewRequests: (obj["reviewRequests"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String ?? $0["name"] as? String },
            commitCount: (obj["commits"] as? [Any])?.count,
            fetchedAt: now)
    }

    /// GitHub's rendered HTML for this PR and every comment/review on it, keyed by node id.
    ///
    /// The ids are the same GraphQL node ids `gh pr view --json comments,reviews` reports, which is
    /// the whole reason this is a second GraphQL call rather than the REST `body_html`: REST hands
    /// back numeric ids that would have to be matched by author and timestamp instead (ADR-090).
    public struct RenderedHTML: Equatable, Sendable {
        public var body: String?
        public var byID: [String: String]
        /// Avatar per login. Keyed by author rather than by node because one person's avatar is the
        /// same in every comment they wrote, and the PR author needs it too (ADR-091).
        public var avatars: [String: URL]
        public init(body: String?, byID: [String: String], avatars: [String: URL] = [:]) {
            self.body = body; self.byID = byID; self.avatars = avatars
        }
    }

    /// Parses the `bodyHTML` GraphQL response.
    public static func parseRenderedHTML(_ data: Data) throws -> RenderedHTML {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pr = ((obj["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"] as? [String: Any] else {
            throw GitHubError(command: "api graphql", exitCode: 0, stderr: "unexpected GraphQL shape (no pullRequest)")
        }
        var byID: [String: String] = [:]
        var avatars: [String: URL] = [:]
        func noteAvatar(_ raw: Any?) {
            guard let a = raw as? [String: Any], let login = a["login"] as? String,
                  let s = a["avatarUrl"] as? String, let url = URL(string: s) else { return }
            avatars[login] = url
        }
        noteAvatar(pr["author"])
        for key in ["comments", "reviews"] {
            for n in (pr[key] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] {
                noteAvatar(n["author"])
                guard let id = n["id"] as? String, let html = n["bodyHTML"] as? String else { continue }
                byID[id] = html
            }
        }
        return RenderedHTML(body: pr["bodyHTML"] as? String, byID: byID, avatars: avatars)
    }

    /// Folds rendered HTML into an already-parsed PR. Anything the payload does not cover keeps
    /// whatever it had, so a partial response degrades to Markdown rather than to blank.
    public func applying(_ html: RenderedHTML) -> PullRequest {
        var copy = self
        if let body = html.body { copy.bodyHTML = body }
        if let avatar = html.avatars[author.graphQLLogin] { copy.author.avatarURL = avatar }
        copy.comments = comments.map { c in
            var c = c
            if let rendered = html.byID[c.id] { c.bodyHTML = rendered }
            if let avatar = html.avatars[c.author.graphQLLogin] { c.author.avatarURL = avatar }
            return c
        }
        return copy
    }

    /// `statusCheckRollup[]` from `gh pr view`: a mix of `CheckRun` (`name/status/conclusion/detailsUrl/workflowName`) and
    /// `StatusContext` (`context/state/targetUrl`) items.
    static func parseRollup(_ raw: Any?) -> [Check] {
        var checks: [Check] = []
        for item in raw as? [[String: Any]] ?? [] {
            let typename = item["__typename"] as? String ?? (item["context"] != nil ? "StatusContext" : "CheckRun")
            let check: Check
            if typename == "StatusContext" {
                let name = item["context"] as? String ?? "status"
                check = Check(id: item["targetUrl"] as? String ?? name, name: name,
                              status: Check.Status(gh: item["state"] as? String ?? ""),
                              detailsURL: url(item["targetUrl"]), workflow: nil,
                              startedAt: date(item["startedAt"]) ?? date(item["createdAt"]), completedAt: nil)
            } else {
                let name = item["name"] as? String ?? "check"
                let status = (item["status"] as? String ?? "").uppercased()
                let conclusion = item["conclusion"] as? String ?? ""
                let resolved: Check.Status = status == "COMPLETED" || !conclusion.isEmpty ? Check.Status(gh: conclusion) : Check.Status(gh: status.isEmpty ? "PENDING" : status)
                check = Check(id: item["detailsUrl"] as? String ?? name, name: name, status: resolved,
                              detailsURL: url(item["detailsUrl"]), workflow: item["workflowName"] as? String,
                              startedAt: date(item["startedAt"]), completedAt: date(item["completedAt"]))
            }
            checks.append(check)
        }
        return uniquingIDs(checks)
    }

    /// `gh pr checks --json name,state,link,workflow,startedAt,completedAt` output.
    static func parseChecksList(_ data: Data) throws -> [Check] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError(command: "pr checks", exitCode: 0, stderr: "unexpected JSON shape (expected an array)")
        }
        return uniquingIDs(items.map { item in
            let name = item["name"] as? String ?? "check"
            return Check(id: item["link"] as? String ?? name, name: name, status: Check.Status(gh: item["state"] as? String ?? ""),
                         detailsURL: url(item["link"]), workflow: item["workflow"] as? String,
                         startedAt: date(item["startedAt"]), completedAt: date(item["completedAt"]))
        })
    }

    private static func uniquingIDs(_ checks: [Check]) -> [Check] {
        var seen: [String: Int] = [:]
        return checks.map { c in
            var c = c
            let n = seen[c.id, default: 0]
            seen[c.id] = n + 1
            if n > 0 { c.id += "#\(n)" }
            return c
        }
    }

    private static func author(_ raw: Any?) -> Author {
        guard let a = raw as? [String: Any], let login = a["login"] as? String, !login.isEmpty else { return Author(login: "ghost") }
        let name = a["name"] as? String
        return Author(login: login, name: name?.isEmpty == true ? nil : name)
    }

    private static func url(_ raw: Any?) -> URL? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func date(_ raw: Any?) -> Date? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return iso.date(from: s) ?? isoFractional.date(from: s)
    }
}

/// The single glyph/colour the sidebar and footer show for a PR (ADR-053).
public struct PullRequestMark: Hashable, Sendable {
    public enum Attention: String, Sendable, CaseIterable {
        case none, checksFailing, conflicts, changesRequested, unansweredComments, checksPending, approved

        /// Higher wins when aggregating; `none` is the floor.
        var severity: Int {
            switch self {
            case .checksFailing: 6
            case .conflicts: 5
            case .changesRequested: 4
            case .unansweredComments: 3
            case .checksPending: 2
            case .approved: 1
            case .none: 0
            }
        }
    }

    /// The plain "this is a pull request" glyph, for every place with no state to show yet: the panel
    /// tab, the footer chip before the PR loads, the sidebar placeholder, and `attention == .none`.
    ///
    /// SF Symbols 6's redraw of the pull symbol, with a solid arrowhead where the old
    /// `arrow.triangle.pull` had a thin open chevron (ADR-089). It only resolves as an arrowhead a
    /// couple of points above the surrounding text, so every site that draws it sizes it explicitly
    /// rather than inheriting a text style — see `PRStyle.glyphSize`.
    public static let symbol = "arrow.trianglehead.pull"

    public var state: PullRequest.State
    public var isDraft: Bool
    public var attention: Attention
    /// SF Symbol name.
    public var symbolName: String
    /// One line, e.g. "Open · 2 checks failing".
    public var summary: String

    /// The tone of the corner dot on the service glyph (ADR-116): the glyph shows the PR's state, the
    /// dot shows what wants attention. Nil when nothing does.
    public var attentionTone: PullRequestStatus.Tone? {
        switch attention {
        case .checksFailing, .conflicts, .changesRequested: .blocking
        case .unansweredComments, .checksPending: .waiting
        case .approved: .good
        case .none: nil
        }
    }

    public init(state: PullRequest.State, isDraft: Bool, attention: Attention, symbolName: String, summary: String) {
        self.state = state; self.isDraft = isDraft; self.attention = attention; self.symbolName = symbolName; self.summary = summary
    }

    /// Merged/closed → none. Otherwise: failing checks > conflicts (`mergeable == CONFLICTING` or `mergeStateStatus == DIRTY`)
    /// > `CHANGES_REQUESTED` > unanswered comments > pending checks > approved. "Unanswered" is
    /// `PullRequestStatus.unansweredComments`, shared with the panel's status block (ADR-087).
    public init(pr: PullRequest, viewerLogin: String?) {
        state = pr.state
        isDraft = pr.isDraft
        let prefix = pr.state == .open ? (pr.isDraft ? "Draft" : "Open") : (pr.state == .merged ? "Merged" : "Closed")
        guard pr.state == .open else {
            attention = .none
            symbolName = pr.state == .merged ? "arrow.trianglehead.merge" : "xmark.circle"
            summary = prefix
            return
        }
        let failing = pr.checks.filter { $0.status == .failure }.count
        let pending = pr.checks.filter { $0.status == .pending }.count
        let unanswered = PullRequestStatus.unansweredComments(pr: pr, viewerLogin: viewerLogin)

        if failing > 0 {
            attention = .checksFailing; symbolName = "xmark.octagon"
            summary = "\(prefix) · \(failing) check\(failing == 1 ? "" : "s") failing"
        } else if pr.mergeable == "CONFLICTING" || pr.mergeStateStatus == "DIRTY" {
            attention = .conflicts; symbolName = "exclamationmark.triangle"
            summary = "\(prefix) · merge conflicts"
        } else if pr.reviewDecision == "CHANGES_REQUESTED" {
            attention = .changesRequested; symbolName = "exclamationmark.bubble"
            summary = "\(prefix) · changes requested"
        } else if unanswered > 0 {
            attention = .unansweredComments; symbolName = "bubble.left"
            summary = "\(prefix) · \(unanswered) unanswered comment\(unanswered == 1 ? "" : "s")"
        } else if pending > 0 {
            attention = .checksPending; symbolName = "clock"
            summary = "\(prefix) · \(pending) check\(pending == 1 ? "" : "s") pending"
        } else if pr.reviewDecision == "APPROVED" {
            attention = .approved; symbolName = "checkmark.circle"
            summary = "\(prefix) · approved"
        } else {
            attention = .none; symbolName = Self.symbol
            summary = prefix
        }
    }

    /// Worst-of across a session's PRs, preferring open PRs. Nil for an empty list.
    public static func aggregate(_ marks: [PullRequestMark]) -> PullRequestMark? {
        let open = marks.filter { $0.state == .open }
        let pool = open.isEmpty ? marks : open
        return pool.max { a, b in
            if a.attention.severity != b.attention.severity { return a.attention.severity < b.attention.severity }
            return false
        }.map { best in
            // max(by:) returns the last of equals; keep the first so the result is stable in list order.
            pool.first { $0.attention.severity == best.attention.severity } ?? best
        }
    }
}
