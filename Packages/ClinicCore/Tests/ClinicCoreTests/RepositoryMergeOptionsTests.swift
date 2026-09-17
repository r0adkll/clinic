import Foundation
import Testing
@testable import ClinicCore

// ADR-164. The fixture is the shape `RepositoryMergeOptions.query` returned live for a repository that
// allows squash only; no test runs `gh`.

private let squashOnly = """
{"data":{"repository":{"mergeCommitAllowed":false,"squashMergeAllowed":true,"rebaseMergeAllowed":false,
  "autoMergeAllowed":true,"viewerDefaultMergeMethod":"SQUASH"}}}
"""

private let ref = PullRequestRef(url: URL(string: "https://github.com/octocat/example/pull/7")!)!
private let opened = Date(timeIntervalSince1970: 1_790_000_000)

private func pr(state: PullRequest.State = .open) -> PullRequest {
    PullRequest(ref: ref, title: "t", state: state, isDraft: false, author: .init(login: "octocat"),
                headRefName: "feature", baseRefName: "main", createdAt: opened, updatedAt: opened,
                mergeable: "MERGEABLE", mergeStateStatus: "CLEAN")
}

@Suite struct RepositoryMergeOptionsTests {
    @Test func readsWhatTheRepositoryAllows() throws {
        let options = try RepositoryMergeOptions.parse(Data(squashOnly.utf8))
        #expect(options.methods == [.squash])
        #expect(options.autoMergeAllowed)
        #expect(options.viewerDefault == .squash)
    }

    @Test func keepsGitHubsMenuOrder() throws {
        let all = #"{"data":{"repository":{"mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":true,"autoMergeAllowed":false,"viewerDefaultMergeMethod":"REBASE"}}}"#
        let options = try RepositoryMergeOptions.parse(Data(all.utf8))
        #expect(options.methods == [.merge, .squash, .rebase])
        #expect(!options.autoMergeAllowed)
        #expect(RepositoryMergeOptions(methods: [.rebase, .merge]).methods == [.merge, .rebase])
    }

    @Test func aShapeWithoutARepositoryThrows() {
        #expect(throws: GitHubError.self) { try RepositoryMergeOptions.parse(Data(#"{"data":{"repository":null}}"#.utf8)) }
    }

    @Test func nothingAllowedIsTreatedAsEverything() {
        #expect(RepositoryMergeOptions(methods: []).methods == GitHubService.MergeMethod.allCases)
    }

    @Test func theSettingsChoiceLeadsWhereItIsAllowed() {
        let squashOnly = RepositoryMergeOptions(methods: [.squash], viewerDefault: .squash)
        #expect(squashOnly.method(preferred: .squash) == .squash)
        #expect(squashOnly.method(preferred: .merge) == .squash)
        let mergeOrRebase = RepositoryMergeOptions(methods: [.merge, .rebase], viewerDefault: .rebase)
        #expect(mergeOrRebase.method(preferred: .merge) == .merge)
        #expect(mergeOrRebase.method(preferred: .squash) == .rebase)
        // A default the repository no longer allows is dropped rather than offered.
        let stale = RepositoryMergeOptions(methods: [.rebase], viewerDefault: .squash)
        #expect(stale.viewerDefault == nil)
        #expect(stale.method(preferred: .merge) == .rebase)
        #expect(RepositoryMergeOptions.unrestricted.method(preferred: .rebase) == .rebase)
    }

    @Test func buildsTheRead() {
        let args = GitHubService.arguments(for: .mergeOptions(ref))
        #expect(args.prefix(4) == ["api", "graphql", "--hostname", "github.com"])
        #expect(args.contains("owner=octocat") && args.contains("repo=example"))
        #expect(!args.contains { $0.hasPrefix("number=") })
    }

    @Test func rereadsOnlyOpenPullRequestsPastTheTTL() {
        let now = opened.addingTimeInterval(10_000)
        #expect(PullRequestRefresh.needsMergeOptions(fresh: pr(), fetchedAt: nil, now: now))
        #expect(!PullRequestRefresh.needsMergeOptions(fresh: pr(), fetchedAt: now.addingTimeInterval(-60), now: now))
        #expect(PullRequestRefresh.needsMergeOptions(fresh: pr(), fetchedAt: now.addingTimeInterval(-PullRequestRefresh.mergeOptionsTTL), now: now))
        #expect(!PullRequestRefresh.needsMergeOptions(fresh: pr(state: .merged), fetchedAt: nil, now: now))
    }

    @Test func autoMergeIsNotOfferedWhereTheRepositoryForbidsIt() {
        let forbidden = PullRequestStatus(pr: pr(), viewerLogin: "octocat",
                                          mergeOptions: RepositoryMergeOptions(methods: [.squash], autoMergeAllowed: false))
        #expect(forbidden.canMerge)
        #expect(!forbidden.canAutoMerge && !forbidden.offersAutoMerge)
        #expect(forbidden.autoMergeBlockedReason == "Auto-merge isn't allowed in this repository")
        let unread = PullRequestStatus(pr: pr(), viewerLogin: "octocat")
        #expect(unread.canAutoMerge && unread.offersAutoMerge)
    }

    @Test func autoMergeIsNotOfferedInAStack() {
        let layer = PullRequestStack.Entry(position: 1, ref: ref, title: "t", state: .open)
        let stack = PullRequestStack(number: 1, size: 1, baseRefName: "main", position: 1, entries: [layer])
        let status = PullRequestStatus(pr: pr(), viewerLogin: "octocat", stack: stack)
        #expect(!status.offersAutoMerge)
    }
}
