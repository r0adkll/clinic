import Foundation
import Testing
@testable import ClinicCore

/// The status block the PR panel leads with (ADR-087). Built straight from `PullRequest` so each
/// case is one initializer rather than a JSON fixture.
@Suite struct PullRequestStatusTests {
    let ref = PullRequestRef(url: URL(string: "https://github.com/octocat/example/pull/42")!)!
    let opened = Date(timeIntervalSince1970: 1_000_000)

    private func check(_ name: String, _ status: PullRequest.Check.Status) -> PullRequest.Check {
        PullRequest.Check(id: name, name: name, status: status)
    }

    private func comment(_ login: String, _ offset: TimeInterval, kind: PullRequest.Comment.Kind = .comment,
                         reviewState: String? = nil) -> PullRequest.Comment {
        PullRequest.Comment(id: "\(login)-\(offset)", kind: kind, author: .init(login: login), body: "hi",
                            createdAt: opened.addingTimeInterval(offset), reviewState: reviewState)
    }

    private func pr(state: PullRequest.State = .open, isDraft: Bool = false, mergeable: String = "MERGEABLE",
                    mergeStateStatus: String = "CLEAN", reviewDecision: String = "", autoMerge: Bool = false,
                    checks: [PullRequest.Check] = [], comments: [PullRequest.Comment] = []) -> PullRequest {
        PullRequest(ref: ref, title: "Ship it", state: state, isDraft: isDraft, author: .init(login: "octocat"),
                    headRefName: "feature", baseRefName: "main", createdAt: opened, updatedAt: opened,
                    mergeable: mergeable, mergeStateStatus: mergeStateStatus, reviewDecision: reviewDecision,
                    autoMergeEnabled: autoMerge, checks: checks, comments: comments)
    }

    private func status(_ pr: PullRequest, viewer: String? = "octocat") -> PullRequestStatus {
        PullRequestStatus(pr: pr, viewerLogin: viewer)
    }

    @Test func failingChecksAreBlockingAndNameTheJobs() {
        let s = status(pr(reviewDecision: "APPROVED",
                          checks: [check("build", .failure), check("test", .failure), check("lint", .success)],
                          comments: [comment("chrisbanes", 60, kind: .review, reviewState: "APPROVED")]))
        let checks = try! #require(s.lines.first { $0.id == "checks" })
        #expect(checks.tone == .blocking)
        #expect(checks.text == "2 checks failing")
        #expect(checks.detail == "build · test")
        // Blocking sorts above the settled lines regardless of the order they were built in.
        #expect(s.lines.first?.id == "checks")
        #expect(s.lines.map(\.id) == ["checks", "merge", "review"])
        #expect(s.action?.title == "Fix the failing checks")
        #expect(s.action?.prompt.contains("build · test") == true)
        #expect(s.action?.prompt.contains("#42") == true)
        // Failing checks do not by themselves stop a merge — GitHub decides that; conflicts and drafts do.
        #expect(s.canMerge)
    }

    @Test func aLongCheckMatrixIsTruncated() {
        let many = (1...7).map { check("job-\($0)", .failure) }
        #expect(PullRequestStatus.names(many) == "job-1 · job-2 · job-3 · +4 more")
        #expect(PullRequestStatus.names([]) == nil)
        #expect(PullRequestStatus.count(1, "check") == "1 check")
        #expect(PullRequestStatus.count(0, "check") == "0 checks")
    }

    @Test func allGreenCollapsesToOneLine() {
        let s = status(pr(checks: [check("build", .success), check("test", .success), check("skip", .skipped)]))
        let checks = try! #require(s.lines.first { $0.id == "checks" })
        #expect(checks.tone == .good)
        #expect(checks.text == "All 3 checks passed")
        #expect(s.action == nil)
        #expect(s.canMerge)
        #expect(s.mergeBlockedReason == nil)
    }

    @Test func pendingChecksGetTheirOwnWaitingLine() {
        let s = status(pr(checks: [check("build", .success), check("deploy", .pending)]))
        #expect(s.lines.first { $0.id == "checks" } == nil)   // not "all passed" while one is running
        let pending = try! #require(s.lines.first { $0.id == "pending" })
        #expect(pending.tone == .waiting)
        #expect(pending.text == "1 check still running")
        #expect(s.action == nil)
    }

    @Test func conflictsBlockTheMergeButton() {
        let s = status(pr(mergeable: "CONFLICTING", mergeStateStatus: "DIRTY", checks: [check("build", .success)]))
        let merge = try! #require(s.lines.first { $0.id == "merge" })
        #expect(merge.tone == .blocking)
        #expect(merge.text == "Conflicts with main")
        #expect(!s.canMerge)
        #expect(s.mergeBlockedReason == "Conflicts with main")
        #expect(s.action?.title == "Resolve the conflicts")
    }

    @Test func behindTheBaseIsWaitingNotBlocking() {
        let s = status(pr(mergeStateStatus: "BEHIND", checks: [check("build", .success)]))
        let merge = try! #require(s.lines.first { $0.id == "merge" })
        #expect(merge.tone == .waiting)
        #expect(merge.text == "Behind main")
        #expect(s.canMerge)
        #expect(s.action == nil)
    }

    @Test func approvalNamesTheReviewers() {
        let s = status(pr(reviewDecision: "APPROVED", checks: [check("build", .success)],
                          comments: [comment("chrisbanes", 60, kind: .review, reviewState: "APPROVED")]))
        let review = try! #require(s.lines.first { $0.id == "review" })
        #expect(review.tone == .good)
        #expect(review.text == "Approved by chrisbanes")
    }

    @Test func changesRequestedIsBlockingAndSuggestsTheCommentsPrompt() {
        let s = status(pr(reviewDecision: "CHANGES_REQUESTED", checks: [check("build", .success)],
                          comments: [comment("chrisbanes", 60, kind: .review, reviewState: "CHANGES_REQUESTED")]))
        let review = try! #require(s.lines.first { $0.id == "review" })
        #expect(review.tone == .blocking)
        #expect(review.detail == "chrisbanes")
        #expect(s.action?.title == "Address the review comments")
    }

    /// Same "unanswered" rule as the sidebar mark, so the panel and the glyph cannot disagree.
    @Test func unansweredCommentsMatchTheMarkRule() {
        let p = pr(checks: [check("build", .success)],
                   comments: [comment("octocat", 30), comment("chrisbanes", 60), comment("dependabot[bot]", 90)])
        let s = status(p)
        let line = try! #require(s.lines.first { $0.id == "comments" })
        #expect(line.tone == .waiting)
        #expect(line.text == "1 unanswered comment")
        #expect(s.action?.title == "Address the review comments")
        #expect(PullRequestStatus.unansweredComments(pr: p, viewerLogin: "octocat")
                == 1)
        // From the other side of the conversation there is nothing outstanding.
        #expect(PullRequestStatus.unansweredComments(pr: p, viewerLogin: "chrisbanes") == 0)
    }

    @Test func draftsCannotMergeAndOfferAReview() {
        let s = status(pr(isDraft: true, checks: [check("build", .success)]))
        // Draft leads, even though it is only neutral: it reframes every settled line below it.
        #expect(s.lines.first?.id == "draft")
        #expect(s.lines.first?.tone == .neutral)
        #expect(!s.canMerge)
        #expect(s.mergeBlockedReason == "Still a draft")
        #expect(s.action?.title == "Review this PR")
    }

    @Test func autoMergeIsStatedRatherThanImplied() {
        let s = status(pr(autoMerge: true, checks: [check("build", .success)]))
        #expect(s.lines.last?.id == "auto")
        #expect(s.lines.last?.text == "Auto-merge is on")
    }

    @Test func mergedAndClosedCollapseToOneNeutralLine() {
        let merged = status(pr(state: .merged, checks: [check("build", .failure)]))
        #expect(merged.lines.map(\.text) == ["Merged into main"])
        #expect(merged.lines.first?.detail == "from feature")
        #expect(!merged.canMerge)
        #expect(merged.mergeBlockedReason == "Already merged")
        #expect(merged.action == nil)

        let closed = status(pr(state: .closed))
        #expect(closed.lines.map(\.text) == ["Closed without merging"])
        #expect(closed.mergeBlockedReason == "Closed")
    }

    /// An unknown mergeability says nothing rather than guessing "no conflicts".
    @Test func unknownMergeabilityIsSilent() {
        let s = status(pr(mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN", checks: [check("build", .success)]))
        #expect(s.lines.first { $0.id == "merge" } == nil)
        #expect(s.canMerge)
    }
}

/// GitHub's own rendering, merged in by node id (ADR-090).
@Suite struct RenderedHTMLTests {
    let ref = PullRequestRef(url: URL(string: "https://github.com/octocat/example/pull/42")!)!

    @Test func splitsRepositoryForGraphQLVariables() {
        #expect(ref.owner == "octocat")
        #expect(ref.name == "example")
        #expect(ref.host == "github.com")
    }

    @Test func argumentsSendNumberAsAnInt() {
        let args = GitHubService.arguments(for: .bodyHTML(ref))
        #expect(args.prefix(4) == ["api", "graphql", "--hostname", "github.com"])
        // `-F` (typed) not `-f` (string): GraphQL rejects a String where Int! is declared.
        #expect(args.contains("-F") && args.contains("number=42"))
        #expect(args.contains("owner=octocat") && args.contains("repo=example"))
        #expect(args.last?.contains("bodyHTML") == true)
    }

    @Test func parsesBodyAndCommentHTMLByNodeID() throws {
        let json = """
        {"data":{"repository":{"pullRequest":{
          "bodyHTML":"<p>hi</p>",
          "comments":{"nodes":[{"id":"IC_1","bodyHTML":"<table></table>"}]},
          "reviews":{"nodes":[{"id":"PRR_1","bodyHTML":"<p>lgtm</p>"}]}
        }}}}
        """
        let html = try PullRequest.parseRenderedHTML(Data(json.utf8))
        #expect(html.body == "<p>hi</p>")
        #expect(html.byID == ["IC_1": "<table></table>", "PRR_1": "<p>lgtm</p>"])
    }

    @Test func mergingKeepsWhatThePayloadDoesNotCover() {
        let opened = Date(timeIntervalSince1970: 1_000_000)
        let comments = [
            PullRequest.Comment(id: "IC_1", kind: .comment, author: .init(login: "a"), body: "raw a", createdAt: opened),
            PullRequest.Comment(id: "IC_2", kind: .comment, author: .init(login: "b"), body: "raw b", createdAt: opened),
        ]
        let pr = PullRequest(ref: ref, title: "t", body: "raw body", state: .open, author: .init(login: "a"),
                             createdAt: opened, updatedAt: opened, comments: comments)
        let merged = pr.applying(.init(body: "<p>body</p>", byID: ["IC_1": "<p>a</p>"]))
        #expect(merged.bodyHTML == "<p>body</p>")
        #expect(merged.comments[0].bodyHTML == "<p>a</p>")
        // Not in the payload: keeps its Markdown and renders as before rather than going blank.
        #expect(merged.comments[1].bodyHTML == nil)
        #expect(merged.comments[1].body == "raw b")

        // A response with no bodyHTML at all must not wipe what is already there.
        let again = merged.applying(.init(body: nil, byID: [:]))
        #expect(again.bodyHTML == "<p>body</p>")
        #expect(again.comments[0].bodyHTML == "<p>a</p>")
    }

    @Test func rejectsAnUnexpectedShape() {
        #expect(throws: GitHubError.self) { try PullRequest.parseRenderedHTML(Data("{\"data\":{}}".utf8)) }
    }
}
