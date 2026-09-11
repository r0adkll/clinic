import Foundation

/// Where work items come from (ADR-113): a provider, the host it lives on, and a provider-defined
/// scope — `owner/repo` for GitHub. A project resolves to zero or more of these; the source is the
/// identity the cache, the filters and the links hang off, never the project.
public struct WorkItemSource: Hashable, Codable, Sendable, Identifiable {
    public var provider: String
    public var host: String
    public var scope: String

    public init(provider: String, host: String, scope: String) {
        self.provider = provider; self.host = host; self.scope = scope
    }

    /// `github:github.com/owner/repo`.
    public var id: String { "\(provider):\(host)/\(scope)" }
    /// The repository half of `owner/repo`, for places too narrow for both.
    public var shortName: String { scope.split(separator: "/").last.map(String.init) ?? scope }
    /// The halves of an `owner/repo` scope, which GraphQL wants separately.
    public var owner: String { String(scope.split(separator: "/").first ?? "") }
    public var repo: String { scope.split(separator: "/").dropFirst().joined(separator: "/") }

    public static func github(_ scope: String, host: String = "github.com") -> WorkItemSource {
        WorkItemSource(provider: GitHubWorkItemProvider.kind, host: host, scope: scope)
    }
    public var webURL: URL? { URL(string: "https://\(host)/\(scope)") }
}

/// One work item's identity: its source and number, and the web URL that names it everywhere else.
public struct WorkItemRef: Hashable, Codable, Sendable, Identifiable {
    public var source: WorkItemSource
    public var number: Int
    public var url: URL

    public init(source: WorkItemSource, number: Int, url: URL) {
        self.source = source; self.number = number; self.url = url
    }

    public var id: String { url.absoluteString }
    /// `owner/repo#123`.
    public var display: String { "\(source.scope)#\(number)" }
    /// `repo#123`.
    public var shortDisplay: String { "\(source.shortName)#\(number)" }
}

public enum WorkItemState: String, Codable, Sendable, CaseIterable { case open, closed }

public struct WorkItemLabel: Hashable, Codable, Sendable {
    public var name: String
    /// Six hex digits, no `#` (GitHub's own form). Nil when the provider has no colour for it.
    public var color: String?
    public init(name: String, color: String? = nil) { self.name = name; self.color = color }
}

/// An issue, normalized (ADR-113). Everything the list, its filters and its search need; the
/// rendered body and comments are a `WorkItemDetail`, fetched only on selection.
public struct WorkItem: Hashable, Codable, Sendable, Identifiable {
    public var ref: WorkItemRef
    public var title: String
    /// Markdown source; searched, never rendered (the detail pane shows the provider's HTML).
    public var body: String
    public var state: WorkItemState
    /// GitHub's `COMPLETED` / `NOT_PLANNED` / `REOPENED`, lowercased; nil when the provider has none.
    public var stateReason: String?
    public var author: String
    public var assignees: [String]
    public var labels: [WorkItemLabel]
    public var milestone: String?
    public var commentCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var closedAt: Date?

    public init(ref: WorkItemRef, title: String, body: String = "", state: WorkItemState = .open, stateReason: String? = nil,
                author: String, assignees: [String] = [], labels: [WorkItemLabel] = [], milestone: String? = nil,
                commentCount: Int = 0, createdAt: Date, updatedAt: Date, closedAt: Date? = nil) {
        self.ref = ref; self.title = title; self.body = body; self.state = state; self.stateReason = stateReason
        self.author = author; self.assignees = assignees; self.labels = labels; self.milestone = milestone
        self.commentCount = commentCount; self.createdAt = createdAt; self.updatedAt = updatedAt; self.closedAt = closedAt
    }

    public var id: String { ref.id }
}

/// What the detail pane shows beyond the list row: the provider's own rendering of the body and the
/// thread, and the pull requests that would close the item (ADR-112).
public struct WorkItemDetail: Hashable, Sendable {
    public struct Comment: Hashable, Sendable, Identifiable {
        public var id: String
        public var author: String
        public var avatarURL: URL?
        public var createdAt: Date
        public var bodyHTML: String
        public var url: URL?
        public init(id: String, author: String, avatarURL: URL? = nil, createdAt: Date, bodyHTML: String, url: URL? = nil) {
            self.id = id; self.author = author; self.avatarURL = avatarURL; self.createdAt = createdAt; self.bodyHTML = bodyHTML; self.url = url
        }
    }

    public struct LinkedPullRequest: Hashable, Sendable, Identifiable {
        public var number: Int
        public var title: String
        public var url: URL
        public var state: PullRequest.State
        public var isDraft: Bool
        public var id: String { url.absoluteString }
        public init(number: Int, title: String, url: URL, state: PullRequest.State, isDraft: Bool = false) {
            self.number = number; self.title = title; self.url = url; self.state = state; self.isDraft = isDraft
        }
    }

    public var ref: WorkItemRef
    public var bodyHTML: String?
    public var authorAvatarURL: URL?
    public var comments: [Comment]
    /// The thread's real length; `comments` stops at the first page.
    public var totalComments: Int
    public var linkedPullRequests: [LinkedPullRequest]
    public var fetchedAt: Date

    public init(ref: WorkItemRef, bodyHTML: String?, authorAvatarURL: URL? = nil, comments: [Comment] = [], totalComments: Int? = nil,
                linkedPullRequests: [LinkedPullRequest] = [], fetchedAt: Date = Date()) {
        self.ref = ref; self.bodyHTML = bodyHTML; self.authorAvatarURL = authorAvatarURL; self.comments = comments
        self.totalComments = totalComments ?? comments.count; self.linkedPullRequests = linkedPullRequests; self.fetchedAt = fetchedAt
    }
}
