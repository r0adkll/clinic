import Foundation

/// The service a pull request lives on, and the words that service uses (ADR-116).
///
/// The panel asks the host for its nouns, its sigil and its button titles rather than spelling
/// GitHub's into every view, so a GitLab merge request reads as one: `!482`, "Pipelines", "Set to
/// auto-merge". Colours and glyphs belong to the app target (`ServiceArt`), because they are SwiftUI;
/// everything here is plain words, so it is a unit test rather than a screenshot.
public struct CodeHost: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable { case github, gitlab }

    /// The three panes of the PR panel (ADR-091), named per service.
    public enum Pane: String, Hashable, Sendable, CaseIterable { case conversation, checks, files }

    /// One piece of the "wants to merge … into … from …" sentence. Branches are separate so the view
    /// can draw them as pills.
    public enum SentencePart: Hashable, Sendable {
        case text(String)
        case branch(String)
    }

    public var kind: Kind
    /// Lowercased: "github.com", an Enterprise host, "gitlab.com", or a self-hosted GitLab.
    public var host: String

    public init(kind: Kind, host: String) {
        self.kind = kind
        self.host = host.lowercased()
    }

    /// GitLab when the host says so: gitlab.com, or a self-hosted instance with `gitlab` as one of its
    /// labels (`gitlab.example.com`, `code.gitlab.example.org`), which is how nearly all are named.
    /// Everything else is GitHub. `gh` is what reads it, and an Enterprise host can be called anything.
    public init(host: String) {
        let labels = host.lowercased().split(separator: ".")
        self.init(kind: labels.contains("gitlab") ? .gitlab : .github, host: host)
    }

    public var name: String {
        switch kind { case .github: "GitHub"; case .gitlab: "GitLab" }
    }

    /// "Pull request" / "Merge request", sentence case.
    public var noun: String {
        switch kind { case .github: "Pull request"; case .gitlab: "Merge request" }
    }

    /// "PR" / "MR".
    public var abbreviation: String {
        switch kind { case .github: "PR"; case .gitlab: "MR" }
    }

    /// "#7" on GitHub, "!482" on GitLab, where `#` means an issue.
    public func reference(_ number: Int) -> String {
        (kind == .gitlab ? "!" : "#") + String(number)
    }

    public var openTitle: String { "Open on \(name)" }

    public func title(_ pane: Pane) -> String {
        switch (kind, pane) {
        case (.github, .conversation): "Conversation"
        case (.github, .checks): "Checks"
        case (.github, .files): "Files changed"
        case (.gitlab, .conversation): "Overview"
        case (.gitlab, .checks): "Pipelines"
        case (.gitlab, .files): "Changes"
        }
    }

    /// The merge button's title, which on GitHub names the method.
    public func mergeTitle(_ method: GitHubService.MergeMethod) -> String {
        switch (kind, method) {
        case (.github, .merge): "Merge pull request"
        case (.github, .squash): "Squash and merge"
        case (.github, .rebase): "Rebase and merge"
        case (.gitlab, _): "Merge"
        }
    }

    /// A method's entry in the merge button's menu.
    public func mergeMethodTitle(_ method: GitHubService.MergeMethod) -> String {
        switch (kind, method) {
        case (.github, .merge): "Create a merge commit"
        case (.github, .squash): "Squash and merge"
        case (.github, .rebase): "Rebase and merge"
        case (.gitlab, .merge): "Merge commit"
        case (.gitlab, .squash): "Squash commits"
        case (.gitlab, .rebase): "Fast-forward merge"
        }
    }

    public var autoMergeTitle: String {
        switch kind { case .github: "Enable auto-merge"; case .gitlab: "Set to auto-merge" }
    }

    public var disableAutoMergeTitle: String {
        switch kind { case .github: "Disable auto-merge"; case .gitlab: "Cancel auto-merge" }
    }

    public var readyTitle: String {
        switch kind { case .github: "Ready for review"; case .gitlab: "Mark as ready" }
    }

    /// What follows the author's name under the title, in the service's own phrasing: GitHub's "wants
    /// to merge 3 commits into main from feature", GitLab's "requested to merge feature into main".
    /// `commits` is nil when the count is unknown, and the sentence then leaves it out.
    public func mergeSentence(state: PullRequest.State, head: String, base: String, commits: Int?) -> [SentencePart] {
        switch kind {
        case .github:
            let verb = state == .merged ? "merged" : "wants to merge"
            let count = commits.map { " \($0) commit\($0 == 1 ? "" : "s")" } ?? ""
            return [.text("\(verb)\(count) into"), .branch(base), .text("from"), .branch(head)]
        case .gitlab:
            return [.text(state == .merged ? "merged" : "requested to merge"), .branch(head), .text("into"), .branch(base)]
        }
    }
}

public extension PullRequestRef {
    /// The service this PR lives on, from its host (ADR-116).
    var codeHost: CodeHost { CodeHost(host: host) }
}
