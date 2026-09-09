import Foundation
import Testing
@testable import ClinicCore

// No test here runs `gh` (CI has no auth). Service coverage stops at argument building.

// MARK: - PullRequestRef

@Suite struct PullRequestRefTests {
    @Test func parsesGitHubDotCom() throws {
        let ref = try #require(PullRequestRef(url: URL(string: "https://github.com/r0adkll/Campfire/pull/1040")!))
        #expect(ref.number == 1040)
        #expect(ref.repository == "r0adkll/Campfire")
        #expect(ref.host == "github.com")
        #expect(ref.url.absoluteString == "https://github.com/r0adkll/Campfire/pull/1040")
        #expect(ref.id == ref.url.absoluteString)
        #expect(!ref.fromPrompt)
    }

    @Test func parsesEnterpriseHostAndCanonicalises() throws {
        let ref = try #require(PullRequestRef(url: URL(string: "https://github.acme.corp/platform/api.git/pull/7/files?diff=split#r1")!, fromPrompt: true))
        #expect(ref.host == "github.acme.corp")
        #expect(ref.repository == "platform/api")
        #expect(ref.number == 7)
        #expect(ref.url.absoluteString == "https://github.acme.corp/platform/api/pull/7")
        #expect(ref.fromPrompt)
    }

    @Test func rejectsNonPRURLs() {
        for s in ["https://github.com/r0adkll/Campfire", "https://github.com/r0adkll/Campfire/issues/12",
                  "https://github.com/r0adkll/Campfire/pull/abc", "https://github.com/pull/12", "file:///tmp/pull/1",
                  "https://gitlab.com/group/proj/-/merge_requests/3"] {
            #expect(PullRequestRef(url: URL(string: s)!) == nil, "\(s)")
        }
    }

    @Test func findsRefsInText() {
        let text = "Review https://github.com/o/r/pull/12 and (https://github.com/o/r/pull/13), then https://github.com/o/r/pull/12 again."
        let refs = PullRequestRef.refs(in: text, fromPrompt: true)
        #expect(refs.map(\.number) == [12, 13])
        #expect(refs.allSatisfy { $0.fromPrompt })
    }
}

// MARK: - PullRequest.parse

/// Trimmed, anonymised `gh pr view --json <viewFields>` capture (merged PR, one failing CheckRun, one bot comment).
private let capturedView = """
{
  "additions": 1423, "deletions": 571, "changedFiles": 41,
  "author": {"id": "MDQ6VXNlcjAwMDAwMDA=", "is_bot": false, "login": "octocat", "name": "Octo Cat"},
  "autoMergeRequest": null,
  "baseRefName": "discover/01-screen",
  "headRefName": "discover/02-background-scan",
  "body": "## Summary\\n\\nStacked on #1032. Moves the Upcoming scan onto a background worker.",
  "comments": [
    {"author": {"login": "github-actions"}, "authorAssociation": "NONE",
     "body": "[Android APK](https://github.com/octocat/example/actions/runs/1/artifacts/2) @ 008120e",
     "createdAt": "2026-09-02T22:49:29Z", "id": "IC_kwDOMYjPjc8AAAABSN6S8Q", "includesCreatedEdit": false,
     "isMinimized": false, "minimizedReason": "", "reactionGroups": [],
     "url": "https://github.com/octocat/example/pull/1040#issuecomment-5517513457", "viewerDidAuthor": false}
  ],
  "createdAt": "2026-09-02T22:36:50Z", "updatedAt": "2026-09-03T01:29:14Z", "mergedAt": "2026-09-03T01:29:12Z",
  "isDraft": false,
  "mergeStateStatus": "DIRTY", "mergeable": "CONFLICTING",
  "number": 1040,
  "reviewDecision": "", "reviews": [],
  "state": "MERGED",
  "statusCheckRollup": [
    {"__typename": "CheckRun", "completedAt": "2026-09-02T22:37:37Z", "conclusion": "SUCCESS",
     "detailsUrl": "https://github.com/octocat/example/actions/runs/33691235329/job/100450190565",
     "name": "danger-pr", "startedAt": "2026-09-02T22:36:57Z", "status": "COMPLETED", "workflowName": "CI"},
    {"__typename": "CheckRun", "completedAt": "2026-09-02T22:37:23Z", "conclusion": "SUCCESS",
     "detailsUrl": "https://github.com/octocat/example/actions/runs/33691235329/job/100450190951",
     "name": "code-style", "startedAt": "2026-09-02T22:36:57Z", "status": "COMPLETED", "workflowName": "CI"},
    {"__typename": "CheckRun", "completedAt": "2026-09-02T22:42:25Z", "conclusion": "FAILURE",
     "detailsUrl": "https://github.com/octocat/example/actions/runs/33691235329/job/100450190836",
     "name": "code-coverage", "startedAt": "2026-09-02T22:36:57Z", "status": "COMPLETED", "workflowName": "CI"}
  ],
  "title": "Run Upcoming scans as background work on Android",
  "url": "https://github.com/octocat/example/pull/1040"
}
"""

/// Hand-written: open PR with a failing CheckRun, a pending StatusContext, a CHANGES_REQUESTED review, and a later
/// human comment. `state`/`mergeable`/`reviewDecision`/`statusCheckRollup` are substituted per test.
private func handWritten(state: String = "OPEN", mergeable: String = "MERGEABLE", mergeStateStatus: String = "BLOCKED",
                         reviewDecision: String = "CHANGES_REQUESTED", checks: String = failingAndPendingChecks,
                         comments: String = laterHumanComment, reviews: String = changesRequestedReview) -> Data {
    Data("""
    {
      "number": 5, "title": "Add widget", "body": "", "state": "\(state)", "isDraft": false,
      "url": "https://github.com/octocat/example/pull/5",
      "author": {"login": "octocat", "name": "Octo Cat"},
      "headRefName": "widget", "baseRefName": "main",
      "createdAt": "2026-09-01T10:00:00Z", "updatedAt": "2026-09-01T12:00:00Z", "mergedAt": null,
      "mergeable": "\(mergeable)", "mergeStateStatus": "\(mergeStateStatus)", "reviewDecision": "\(reviewDecision)",
      "autoMergeRequest": {"enabledAt": "2026-09-01T10:30:00Z", "mergeMethod": "SQUASH"},
      "additions": 10, "deletions": 2, "changedFiles": 1,
      "statusCheckRollup": [\(checks)],
      "comments": [\(comments)],
      "reviews": [\(reviews)]
    }
    """.utf8)
}

private let failingAndPendingChecks = """
{"__typename": "CheckRun", "name": "unit", "status": "COMPLETED", "conclusion": "FAILURE", "detailsUrl": "https://ci.example/unit", "workflowName": "CI", "startedAt": "2026-09-01T10:01:00Z", "completedAt": "2026-09-01T10:05:00Z"},
{"__typename": "CheckRun", "name": "lint", "status": "IN_PROGRESS", "conclusion": "", "detailsUrl": "https://ci.example/lint", "workflowName": "CI"},
{"__typename": "StatusContext", "context": "ci/circleci: build", "state": "PENDING", "targetUrl": "https://circleci.example/1"}
"""
private let greenChecks = """
{"__typename": "CheckRun", "name": "unit", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "https://ci.example/unit"},
{"__typename": "StatusContext", "context": "ci/circleci: build", "state": "SUCCESS", "targetUrl": "https://circleci.example/1"}
"""
private let changesRequestedReview = """
{"id": "PRR_1", "author": {"login": "reviewer"}, "authorAssociation": "MEMBER", "body": "Please rename this.", "submittedAt": "2026-09-01T11:00:00Z", "state": "CHANGES_REQUESTED", "url": "https://github.com/octocat/example/pull/5#pullrequestreview-1"}
"""
private let laterHumanComment = """
{"id": "IC_1", "author": {"login": "octocat"}, "body": "Renamed.", "createdAt": "2026-09-01T11:30:00Z", "url": "https://github.com/octocat/example/pull/5#issuecomment-1"},
{"id": "IC_2", "author": {"login": "reviewer"}, "body": "One more thing…", "createdAt": "2026-09-01T11:45:00Z", "url": "https://github.com/octocat/example/pull/5#issuecomment-2"},
{"id": "IC_3", "author": {"login": "dependabot[bot]"}, "body": "bump", "createdAt": "2026-09-01T11:50:00Z"}
"""

@Suite struct PullRequestParseTests {
    let ref = PullRequestRef(url: URL(string: "https://github.com/octocat/example/pull/1040")!)!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func parsesCapturedView() throws {
        let pr = try PullRequest.parse(Data(capturedView.utf8), ref: ref, now: now)
        #expect(pr.id == ref.id)
        #expect(pr.title == "Run Upcoming scans as background work on Android")
        #expect(pr.body.hasPrefix("## Summary"))
        #expect(pr.state == .merged)
        #expect(!pr.isDraft)
        #expect(pr.author == PullRequest.Author(login: "octocat", name: "Octo Cat"))
        #expect(pr.headRefName == "discover/02-background-scan" && pr.baseRefName == "discover/01-screen")
        #expect(pr.createdAt == PullRequest.date("2026-09-02T22:36:50Z"))
        #expect(pr.updatedAt == PullRequest.date("2026-09-03T01:29:14Z"))
        #expect(pr.mergedAt == PullRequest.date("2026-09-03T01:29:12Z"))
        #expect(pr.mergeable == "CONFLICTING" && pr.mergeStateStatus == "DIRTY")
        #expect(pr.reviewDecision == "")
        #expect(!pr.autoMergeEnabled)
        #expect(pr.additions == 1423 && pr.deletions == 571 && pr.changedFiles == 41)
        #expect(pr.fetchedAt == now)

        #expect(pr.checks.map(\.name) == ["danger-pr", "code-style", "code-coverage"])
        #expect(pr.checks.map(\.status) == [.success, .success, .failure])
        #expect(pr.checks[2].workflow == "CI")
        #expect(pr.checks[2].detailsURL?.absoluteString == "https://github.com/octocat/example/actions/runs/33691235329/job/100450190836")
        #expect(pr.checks[2].completedAt == PullRequest.date("2026-09-02T22:42:25Z"))
        #expect(Set(pr.checks.map(\.id)).count == 3)

        #expect(pr.comments.count == 1)
        let c = pr.comments[0]
        #expect(c.kind == .comment && c.id == "IC_kwDOMYjPjc8AAAABSN6S8Q")
        #expect(c.author.login == "github-actions" && c.author.isBot)
        #expect(c.url?.fragment == "issuecomment-5517513457")
        #expect(c.reviewState == nil)
    }

    @Test func mapsBothRollupShapesAndMergesReviews() throws {
        let pr = try PullRequest.parse(handWritten(), ref: ref, now: now)
        #expect(pr.state == .open)
        #expect(pr.autoMergeEnabled)
        #expect(pr.checks.map(\.status) == [.failure, .pending, .pending])
        #expect(pr.checks[2].name == "ci/circleci: build")
        #expect(pr.checks[2].detailsURL?.absoluteString == "https://circleci.example/1")
        #expect(pr.checks[2].workflow == nil)
        #expect(pr.checks[1].startedAt == nil)

        // comments + reviews merged and sorted chronologically
        #expect(pr.comments.map(\.id) == ["PRR_1", "IC_1", "IC_2", "IC_3"])
        #expect(pr.comments[0].kind == .review && pr.comments[0].reviewState == "CHANGES_REQUESTED")
        #expect(pr.comments[0].createdAt == PullRequest.date("2026-09-01T11:00:00Z"))
        #expect(pr.comments[1].kind == .comment)
        #expect(pr.comments[3].author.isBot)
    }

    @Test func toleratesMissingAndOddFields() throws {
        let minimal = Data(#"{"number": 9, "author": null, "statusCheckRollup": null, "comments": null, "createdAt": "2026-09-01T10:00:00.123Z"}"#.utf8)
        let pr = try PullRequest.parse(minimal, ref: ref, now: now)
        #expect(pr.state == .open)
        #expect(pr.author.login == "ghost")
        #expect(pr.checks.isEmpty && pr.comments.isEmpty)
        #expect(pr.mergeable == "UNKNOWN" && pr.mergeStateStatus == "UNKNOWN" && pr.reviewDecision == "")
        #expect(pr.createdAt == PullRequest.date("2026-09-01T10:00:00.123Z"))
        #expect(pr.updatedAt == pr.createdAt)

        #expect(throws: GitHubError.self) { try PullRequest.parse(Data("[]".utf8), ref: ref) }
        #expect(throws: GitHubError.self) { try PullRequest.parse(Data("{}".utf8), ref: ref) }
        #expect(throws: (any Error).self) { try PullRequest.parse(Data("nope".utf8), ref: ref) }
    }

    @Test func parsesChecksListAndDuplicateIDs() throws {
        let json = Data("""
        [{"name": "build", "state": "SUCCESS", "link": "https://ci.example/1", "workflow": "CI", "startedAt": "2026-09-01T10:00:00Z", "completedAt": "2026-09-01T10:02:00Z"},
         {"name": "build", "state": "IN_PROGRESS", "link": "https://ci.example/1", "workflow": "CI"},
         {"name": "deploy", "state": "CANCELLED"}, {"name": "docs", "state": "SKIPPED"}, {"name": "x", "state": "WEIRD"}]
        """.utf8)
        let checks = try PullRequest.parseChecksList(json)
        #expect(checks.map(\.status) == [.success, .pending, .cancelled, .skipped, .unknown])
        #expect(checks.map(\.id) == ["https://ci.example/1", "https://ci.example/1#1", "deploy", "docs", "x"])
        #expect(checks[0].completedAt == PullRequest.date("2026-09-01T10:02:00Z"))
    }

    @Test func roundTripsThroughCodable() throws {
        let pr = try PullRequest.parse(handWritten(), ref: ref, now: now)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(PullRequest.self, from: enc.encode(pr))
        #expect(back == pr)
    }
}

// MARK: - PullRequestMark

@Suite struct PullRequestMarkTests {
    let ref = PullRequestRef(url: URL(string: "https://github.com/octocat/example/pull/5")!)!

    private func pr(_ data: Data) throws -> PullRequest { try PullRequest.parse(data, ref: ref) }

    @Test func failingChecksWinOverEverything() throws {
        let mark = PullRequestMark(pr: try pr(handWritten(mergeable: "CONFLICTING")), viewerLogin: "octocat")
        #expect(mark.attention == .checksFailing)
        #expect(mark.state == .open && !mark.isDraft)
        #expect(mark.symbolName == "xmark.octagon")
        #expect(mark.summary == "Open · 1 check failing")
    }

    @Test func conflictsBeatChangesRequested() throws {
        #expect(PullRequestMark(pr: try pr(handWritten(mergeable: "CONFLICTING", checks: greenChecks)), viewerLogin: "octocat").attention == .conflicts)
        #expect(PullRequestMark(pr: try pr(handWritten(mergeStateStatus: "DIRTY", checks: greenChecks)), viewerLogin: "octocat").attention == .conflicts)
    }

    @Test func changesRequestedBeatsUnansweredComments() throws {
        let mark = PullRequestMark(pr: try pr(handWritten(checks: greenChecks)), viewerLogin: "octocat")
        #expect(mark.attention == .changesRequested)
        #expect(mark.summary == "Open · changes requested")
    }

    @Test func foreignCommentNewerThanViewersIsUnanswered() throws {
        // Green checks, no review decision, reviewer's comment (11:45) is after octocat's last (11:30); the bot's 11:50 comment does not count.
        let mark = PullRequestMark(pr: try pr(handWritten(reviewDecision: "", checks: greenChecks)), viewerLogin: "octocat")
        #expect(mark.attention == .unansweredComments)
        #expect(mark.symbolName == "bubble.left")
        #expect(mark.summary == "Open · 1 unanswered comment")

        // From the reviewer's point of view nothing is unanswered (octocat replied before the reviewer's last comment).
        #expect(PullRequestMark(pr: try pr(handWritten(reviewDecision: "", checks: greenChecks)), viewerLogin: "reviewer").attention == .none)
        // Unknown viewer falls back to the PR author.
        #expect(PullRequestMark(pr: try pr(handWritten(reviewDecision: "", checks: greenChecks)), viewerLogin: nil).attention == .unansweredComments)
    }

    @Test func answeredCommentsFallThroughToPendingThenApproved() throws {
        let answered = """
        {"id": "IC_2", "author": {"login": "reviewer"}, "body": "One more thing…", "createdAt": "2026-09-01T11:45:00Z"},
        {"id": "IC_1", "author": {"login": "octocat"}, "body": "Done.", "createdAt": "2026-09-01T11:50:00Z"}
        """
        let pending = PullRequestMark(pr: try pr(handWritten(reviewDecision: "APPROVED", checks: failingAndPendingChecks.replacingOccurrences(of: "\"FAILURE\"", with: "\"SUCCESS\""), comments: answered, reviews: "")), viewerLogin: "octocat")
        #expect(pending.attention == .checksPending)
        #expect(pending.summary == "Open · 2 checks pending")

        let approved = PullRequestMark(pr: try pr(handWritten(reviewDecision: "APPROVED", checks: greenChecks, comments: answered, reviews: "")), viewerLogin: "octocat")
        #expect(approved.attention == .approved)
        #expect(approved.symbolName == "checkmark.circle")
        #expect(approved.summary == "Open · approved")

        let plain = PullRequestMark(pr: try pr(handWritten(reviewDecision: "", checks: greenChecks, comments: answered, reviews: "")), viewerLogin: "octocat")
        #expect(plain.attention == .none)
        #expect(plain.symbolName == PullRequestMark.symbol)
        #expect(plain.summary == "Open")
    }

    @Test func mergedAndClosedAreNoneEvenWhenDirty() throws {
        let merged = PullRequestMark(pr: try PullRequest.parse(Data(capturedView.utf8), ref: ref), viewerLogin: "octocat")
        #expect(merged.attention == .none && merged.state == .merged)
        #expect(merged.summary == "Merged")
        let closed = PullRequestMark(pr: try pr(handWritten(state: "CLOSED")), viewerLogin: "octocat")
        #expect(closed.attention == .none && closed.state == .closed && closed.summary == "Closed")
    }

    @Test func draftPrefix() throws {
        var p = try pr(handWritten(reviewDecision: "", checks: greenChecks, comments: "", reviews: ""))
        p.isDraft = true
        let mark = PullRequestMark(pr: p, viewerLogin: "octocat")
        #expect(mark.isDraft && mark.summary == "Draft")
    }

    @Test func aggregatePrefersOpenAndWorstAttention() {
        func mark(_ state: PullRequest.State, _ attention: PullRequestMark.Attention) -> PullRequestMark {
            PullRequestMark(state: state, isDraft: false, attention: attention, symbolName: "", summary: attention.rawValue)
        }
        #expect(PullRequestMark.aggregate([]) == nil)

        let openApproved = mark(.open, .approved), openPending = mark(.open, .checksPending), openFailing = mark(.open, .checksFailing)
        let merged = mark(.merged, .none), openNone = mark(.open, .none)
        #expect(PullRequestMark.aggregate([merged, openApproved])?.state == .open)
        #expect(PullRequestMark.aggregate([openApproved, openFailing, openPending])?.attention == .checksFailing)
        #expect(PullRequestMark.aggregate([openNone, merged])?.state == .open)
        #expect(PullRequestMark.aggregate([merged, mark(.closed, .none)])?.state == .merged)
        // Stable: first of equals.
        let a = mark(.open, .approved), b = PullRequestMark(state: .open, isDraft: true, attention: .approved, symbolName: "", summary: "b")
        #expect(PullRequestMark.aggregate([a, b]) == a)
    }
}

// MARK: - GitHubService argument building (no process is launched)

@Suite struct GitHubServiceArgumentTests {
    let ref = PullRequestRef(url: URL(string: "https://github.com/octocat/example/pull/42")!)!

    @Test func buildsGhArguments() {
        let url = "https://github.com/octocat/example/pull/42"
        #expect(GitHubService.arguments(for: .authStatus) == ["auth", "status"])
        #expect(GitHubService.arguments(for: .viewer) == ["api", "user", "--jq", ".login"])
        #expect(GitHubService.arguments(for: .view(ref)) == ["pr", "view", url, "--json", GitHubService.viewFields.joined(separator: ",")])
        #expect(GitHubService.arguments(for: .diff(ref)) == ["pr", "diff", url])
        #expect(GitHubService.arguments(for: .ready(ref)) == ["pr", "ready", url])
        #expect(GitHubService.arguments(for: .merge(ref, .squash, auto: false)) == ["pr", "merge", url, "--squash"])
        #expect(GitHubService.arguments(for: .merge(ref, .rebase, auto: true)) == ["pr", "merge", url, "--rebase", "--auto"])
        #expect(GitHubService.arguments(for: .disableAutoMerge(ref)) == ["pr", "merge", url, "--disable-auto"])
        #expect(GitHubService.arguments(for: .checks(ref)) == ["pr", "checks", url, "--json", "name,state,link,workflow,startedAt,completedAt"])
    }

    @Test func viewFieldsMatchContract() {
        #expect(GitHubService.viewFields.joined(separator: ",") ==
                "number,title,body,state,isDraft,url,author,headRefName,baseRefName,createdAt,updatedAt,mergedAt,mergeable,mergeStateStatus,reviewDecision,autoMergeRequest,additions,deletions,changedFiles,statusCheckRollup,comments,reviews")
        #expect(GitHubService.MergeMethod.allCases.map(\.rawValue) == ["merge", "squash", "rebase"])
    }

    @Test func errorDescription() {
        #expect(GitHubError(command: "pr merge x", exitCode: 1, stderr: "  boom \n").description == "gh pr merge x failed (exit 1): boom")
        #expect(GitHubError(command: "auth status", exitCode: 4, stderr: "").description == "gh auth status failed (exit 4)")
    }

    @Test func toolPathsArePrependedOnce() {
        // `~/.local/bin` is where Claude Code's installer puts `claude`, so it joins the tool paths (ADR-084).
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        #expect(ProcessEnvironment.toolPaths == ["/opt/homebrew/bin", "/usr/local/bin", local])
        let env = ProcessEnvironment.withToolPaths(base: ["PATH": "/usr/bin:/opt/homebrew/bin:/bin"], login: [])
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:\(local):/usr/bin:/bin")
        #expect(ProcessEnvironment.withToolPaths(base: [:], login: [])["PATH"] == "/opt/homebrew/bin:/usr/local/bin:\(local):/usr/bin:/bin")
    }

    /// The login shell's `PATH` goes behind what we inherited, and nothing is repeated (ADR-086).
    @Test func loginShellPathIsAppendedWithoutDuplicates() {
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        let env = ProcessEnvironment.withToolPaths(base: ["PATH": "/usr/bin:/bin"],
                                                   login: ["/opt/homebrew/bin", "/nix/profile/bin", "/usr/bin"])
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:\(local):/usr/bin:/bin:/nix/profile/bin")
    }

    @Test func loginShellPathParsesLastLineOnly() {
        // A profile that prints a banner must not turn into a PATH entry.
        #expect(ProcessEnvironment.parsePath("welcome home!\n/opt/homebrew/bin:/usr/bin\n") == ["/opt/homebrew/bin", "/usr/bin"])
        #expect(ProcessEnvironment.parsePath("") == [])
        #expect(ProcessEnvironment.parsePath("not-a-path\n") == [])
    }

    /// A missing `gh` and a logged-out `gh` need different messages, so they must not collapse (ADR-086).
    @Test func availabilityDistinguishesMissingFromLoggedOut() {
        func result(_ status: Int32, _ stderr: String) -> ToolProcess.Result {
            ToolProcess.Result(status: status, stdout: Data(), stderr: stderr)
        }
        #expect(GitHubService.classify(result(0, ""), executable: "gh", path: "/usr/bin") == .ready)
        #expect(GitHubService.classify(result(127, "env: gh: No such file or directory"), executable: "gh", path: "/usr/bin")
                == .notInstalled(searchedPath: "/usr/bin"))
        #expect(GitHubService.classify(result(-1, "could not launch gh"), executable: "gh", path: "/usr/bin")
                == .notInstalled(searchedPath: "/usr/bin"))
        #expect(GitHubService.classify(result(1, "  You are not logged into any GitHub hosts.\n"), executable: "gh", path: "/usr/bin")
                == .notAuthenticated("You are not logged into any GitHub hosts."))
    }
}

// MARK: - Transcript PR links

@Suite struct TranscriptPullRequestTests {
    let reader = TranscriptReader()

    @Test func collectsAndDeduplicatesPrLinks() {
        var head = TranscriptFixture()
        head.user("Ship the widget", at: "2026-09-07T10:00:00.000Z")
        head.prLink(number: 12, at: "2026-09-07T10:30:00.000Z")
        head.prLink(number: 13, repo: "octocat/other", at: "2026-09-07T10:40:00.000Z")
        var tail = TranscriptFixture()
        tail.prLink(number: 12, at: "2026-09-07T11:00:00.000Z")
        // The tail's first line is always treated as partial (seek landed mid-record).
        let tailData = Data("garbage-partial-line\n".utf8) + tail.data
        let s = reader.parse(id: head.sessionId, path: "p", head: head.data, tail: tailData, size: 999_999)
        #expect(s.pullRequests.map(\.number) == [13, 12])
        #expect(s.pullRequests.map(\.repository) == ["octocat/other", "octocat/example"])
        #expect(s.pullRequests.allSatisfy { !$0.fromPrompt && $0.host == "github.com" })
        #expect(s.pullRequests[1].url.absoluteString == "https://github.com/octocat/example/pull/12")
    }

    @Test func promptURLIsDetectedAndMergedWithLaterLink() {
        var f = TranscriptFixture()
        f.user("Please review https://github.com/octocat/example/pull/12 and fix CI", at: "2026-09-07T10:00:00.000Z")
        f.user("Now https://github.com/octocat/example/pull/99", at: "2026-09-07T10:05:00.000Z")   // not the first prompt
        f.prLink(number: 12)
        let s = reader.parse(id: f.sessionId, path: "p", head: f.data, tail: Data())
        #expect(s.pullRequests.count == 1)
        #expect(s.pullRequests[0].number == 12)
        #expect(s.pullRequests[0].fromPrompt)
    }

    @Test func prLinkWithoutURLFallsBackToNumberAndRepo() {
        var f = TranscriptFixture()
        f.raw(#"{"type":"pr-link","sessionId":"x","prNumber":7,"prRepository":"octocat/example"}"#)
        f.raw(#"{"type":"pr-link","sessionId":"x","prNumber":8}"#)
        let s = reader.parse(id: f.sessionId, path: "p", head: f.data, tail: Data())
        #expect(s.pullRequests.map(\.number) == [7])
    }

    @Test func summaryDecodesWithoutPullRequestsKey() throws {
        let json = Data(#"{"id":"abc","transcriptPath":"p","fileSize":1,"fileModifiedAt":"2026-09-07T10:00:00Z"}"#.utf8)
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let s = try d.decode(SessionSummary.self, from: json)
        #expect(s.pullRequests.isEmpty)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        var withPR = s
        withPR.pullRequests = [PullRequestRef(url: URL(string: "https://github.com/o/r/pull/1")!, fromPrompt: true)!]
        #expect(try d.decode(SessionSummary.self, from: e.encode(withPR)) == withPR)
    }
}
