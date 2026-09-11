import Foundation
import Testing
@testable import ClinicCore

/// The service identity layer of the PR panel (ADR-116): which forge a PR lives on, the words it
/// uses, who ran each check, and the reviewer and diffstat summaries the header draws.
@Suite struct CodeHostTests {
    let opened = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Host

    @Test func hostKindComesFromTheHostName() {
        #expect(CodeHost(host: "github.com").kind == .github)
        #expect(CodeHost(host: "GitLab.com").kind == .gitlab)
        #expect(CodeHost(host: "gitlab.example.com").kind == .gitlab)
        #expect(CodeHost(host: "code.gitlab.example.org").kind == .gitlab)
        // An Enterprise host can be called anything; `gh` reads it, so it is GitHub.
        #expect(CodeHost(host: "git.corp.example.com").kind == .github)
        #expect(CodeHost(host: "gitlabber.io").kind == .github)
        #expect(CodeHost(host: "GitLab.com").host == "gitlab.com")
    }

    @Test func refCarriesItsHost() {
        let ref = PullRequestRef(url: URL(string: "https://ghe.example.com/octo/app/pull/9")!)!
        #expect(ref.codeHost == CodeHost(kind: .github, host: "ghe.example.com"))
    }

    @Test func vocabularyFollowsTheService() {
        let gh = CodeHost(kind: .github, host: "github.com")
        let gl = CodeHost(kind: .gitlab, host: "gitlab.com")
        #expect(gh.reference(7) == "#7")
        #expect(gl.reference(482) == "!482")
        #expect((gh.noun, gh.abbreviation, gh.openTitle) == ("Pull request", "PR", "Open on GitHub"))
        #expect((gl.noun, gl.abbreviation, gl.openTitle) == ("Merge request", "MR", "Open on GitLab"))
        #expect(CodeHost.Pane.allCases.map(gh.title) == ["Conversation", "Checks", "Files changed"])
        #expect(CodeHost.Pane.allCases.map(gl.title) == ["Overview", "Pipelines", "Changes"])
        #expect(gh.mergeTitle(.squash) == "Squash and merge")
        #expect(gh.mergeTitle(.merge) == "Merge pull request")
        #expect(gh.mergeMethodTitle(.merge) == "Create a merge commit")
        #expect(gl.mergeTitle(.squash) == "Merge")
        #expect((gh.autoMergeTitle, gl.autoMergeTitle) == ("Enable auto-merge", "Set to auto-merge"))
    }

    @Test func mergeSentenceIsPhrasedLikeTheService() {
        let gh = CodeHost(host: "github.com"), gl = CodeHost(host: "gitlab.com")
        #expect(gh.mergeSentence(state: .open, head: "feature", base: "main", commits: 3)
                == [.text("wants to merge 3 commits into"), .branch("main"), .text("from"), .branch("feature")])
        #expect(gh.mergeSentence(state: .merged, head: "feature", base: "main", commits: 1).first == .text("merged 1 commit into"))
        #expect(gh.mergeSentence(state: .open, head: "f", base: "main", commits: nil).first == .text("wants to merge into"))
        #expect(gl.mergeSentence(state: .open, head: "feature", base: "main", commits: 3)
                == [.text("requested to merge"), .branch("feature"), .text("into"), .branch("main")])
    }

    // MARK: Check provider

    private func check(_ url: String?, workflow: String? = nil) -> PullRequest.Check {
        PullRequest.Check(id: url ?? "x", name: "x", status: .success, detailsURL: url.flatMap(URL.init(string:)), workflow: workflow)
    }

    @Test func providerComesFromTheDetailsLink() {
        #expect(CheckProvider(check("https://github.com/o/r/actions/runs/1/job/2")) == .githubActions)
        #expect(CheckProvider(check("https://ghe.corp.example/o/r/actions/runs/1")) == .githubActions)
        #expect(CheckProvider(check("https://app.circleci.com/pipelines/gh/o/r/1")) == .circleCI)
        #expect(CheckProvider(check("https://buildkite.com/o/p/builds/1")) == .buildkite)
        #expect(CheckProvider(check("https://vercel.com/o/p/abc")) == .vercel)
        #expect(CheckProvider(check("https://app.netlify.com/sites/x/deploys/1")) == .netlify)
        #expect(CheckProvider(check("https://app.codecov.io/gh/o/r/pull/1")) == .codecov)
        #expect(CheckProvider(check("https://jenkins.corp.example/job/1")) == .jenkins)
        #expect(CheckProvider(check("https://gitlab.com/o/r/-/pipelines/12")) == .gitlabCI)
        #expect(CheckProvider(check("https://example.com/status")) == .other)
        // Not a lookalike domain.
        #expect(CheckProvider(check("https://notcircleci.com/x")) == .other)
    }

    @Test func aWorkflowNameMeansActionsWhenTheLinkSaysNothing() {
        #expect(CheckProvider(check(nil, workflow: "CI")) == .githubActions)
        #expect(CheckProvider(check(nil, workflow: "")) == .other)
        #expect(CheckProvider(check(nil)) == .other)
        #expect(CheckProvider.githubActions.name == "GitHub Actions")
    }

    // MARK: Reviewers

    private func review(_ login: String, _ state: String, _ offset: TimeInterval) -> PullRequest.Comment {
        PullRequest.Comment(id: "\(login)-\(offset)", kind: .review, author: .init(login: login), body: "",
                            createdAt: opened.addingTimeInterval(offset), reviewState: state)
    }

    private func pr(comments: [PullRequest.Comment] = [], requests: [String] = []) -> PullRequest {
        PullRequest(ref: PullRequestRef(url: URL(string: "https://github.com/o/r/pull/1")!)!, title: "t", state: .open,
                    author: .init(login: "octocat"), createdAt: opened, updatedAt: opened,
                    comments: comments, reviewRequests: requests)
    }

    @Test func aCommentDoesNotWithdrawAVerdict() {
        let r = pr(comments: [review("ana", "APPROVED", 10), review("ana", "COMMENTED", 20),
                              review("bo", "COMMENTED", 30), review("bo", "CHANGES_REQUESTED", 40)]).reviewers
        #expect(r.map(\.login) == ["ana", "bo"])
        #expect(r.map(\.verdict) == [.approved, .changesRequested])
    }

    @Test func dismissalAndRequestsAndTheAuthor() {
        let r = pr(comments: [review("ana", "CHANGES_REQUESTED", 10), review("ana", "DISMISSED", 20),
                              review("octocat", "COMMENTED", 30)],
                   requests: ["cy", "ana", "core-team"]).reviewers
        #expect(r.map(\.login) == ["ana", "cy", "core-team"])
        #expect(r.map(\.verdict) == [.commented, .requested, .requested])
    }

    // MARK: Diffstat

    @Test func diffstatSplitsFiveSquares() {
        #expect(PullRequest.diffstatBlocks(additions: 612, deletions: 148) == (4, 1))
        #expect(PullRequest.diffstatBlocks(additions: 10, deletions: 0) == (5, 0))
        #expect(PullRequest.diffstatBlocks(additions: 0, deletions: 10) == (0, 5))
        // A side that changed anything keeps a square, however lopsided the change.
        #expect(PullRequest.diffstatBlocks(additions: 1000, deletions: 1) == (4, 1))
        #expect(PullRequest.diffstatBlocks(additions: 1, deletions: 1000) == (1, 4))
        #expect(PullRequest.diffstatBlocks(additions: 0, deletions: 0) == (0, 0))
    }

    // MARK: Parsing and the mark

    @Test func parsesLabelsRequestsAndCommits() throws {
        let json = """
        {"number": 7, "title": "t", "state": "OPEN",
         "labels": [{"id": "L1", "name": "ui", "color": "1d76db", "description": ""}, {"name": "bug"}],
         "reviewRequests": [{"__typename": "User", "login": "ana"}, {"__typename": "Team", "name": "core", "slug": "core"}],
         "commits": [{"oid": "a"}, {"oid": "b"}, {"oid": "c"}]}
        """
        let ref = PullRequestRef(url: URL(string: "https://github.com/o/r/pull/7")!)!
        let parsed = try PullRequest.parse(Data(json.utf8), ref: ref)
        #expect(parsed.labels == [WorkItemLabel(name: "ui", color: "1d76db"), WorkItemLabel(name: "bug")])
        #expect(parsed.reviewRequests == ["ana", "core"])
        #expect(parsed.commitCount == 3)
        let bare = try PullRequest.parse(Data(#"{"number": 7}"#.utf8), ref: ref)
        #expect(bare.labels.isEmpty && bare.reviewRequests.isEmpty && bare.commitCount == nil)
    }

    @Test func appAuthorsAreBotsAndFindTheirAvatars() {
        let app = PullRequest.Author(login: "app/dependabot")
        #expect(app.isBot)
        #expect(!PullRequest.Author(login: "apple").isBot)
        var p = pr()
        p.author = app
        let url = URL(string: "https://avatars.example/dependabot")!
        #expect(p.applying(.init(body: nil, byID: [:], avatars: ["dependabot": url])).author.avatarURL == url)
    }

    @Test func attentionToneFollowsTheMark() {
        func mark(_ a: PullRequestMark.Attention) -> PullRequestMark {
            PullRequestMark(state: .open, isDraft: false, attention: a, symbolName: "", summary: "")
        }
        #expect(mark(.checksFailing).attentionTone == .blocking)
        #expect(mark(.conflicts).attentionTone == .blocking)
        #expect(mark(.changesRequested).attentionTone == .blocking)
        #expect(mark(.unansweredComments).attentionTone == .waiting)
        #expect(mark(.checksPending).attentionTone == .waiting)
        #expect(mark(.approved).attentionTone == .good)
        #expect(mark(.none).attentionTone == nil)
    }
}
