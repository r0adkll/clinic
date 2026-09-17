import Foundation
import Testing
@testable import ClinicCore

// ADR-163. No test runs `gh`; the fixture is a trimmed, anonymised capture of `PullRequestStack.query`
// against a live seven-layer stack, cut to four layers, viewed from layer 3.

private let capturedStack = """
{"data":{"repository":{"pullRequest":{
  "stackEntry":{"position":3},
  "stack":{"number":457,"size":4,"baseRefName":"trunk","entries":{"nodes":[
    {"position":2,"pullRequest":{"number":451,"url":"https://github.com/octocat/example/pull/451","title":"Tokens (2/4): domain",
      "state":"OPEN","isDraft":false,"headRefName":"tokens-b","mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED",
      "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}},
    {"position":1,"pullRequest":{"number":450,"url":"https://github.com/octocat/example/pull/450","title":"Tokens (1/4): foundation",
      "state":"OPEN","isDraft":false,"headRefName":"tokens-a","mergeable":"CONFLICTING","reviewDecision":"REVIEW_REQUIRED",
      "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}},
    {"position":3,"pullRequest":{"number":452,"url":"https://github.com/octocat/example/pull/452","title":"Tokens (3/4): login",
      "state":"OPEN","isDraft":false,"headRefName":"tokens-c","mergeable":"MERGEABLE","reviewDecision":"APPROVED",
      "commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}},
    {"position":4,"pullRequest":{"number":453,"url":"https://github.com/octocat/example/pull/453","title":"Tokens (4/4): e2e",
      "state":"OPEN","isDraft":true,"headRefName":"tokens-d","mergeable":"UNKNOWN","reviewDecision":"",
      "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING"}}}]}}}
  ]}}
}}}}
"""

private func ref(_ n: Int, repo: String = "octocat/example") -> PullRequestRef {
    PullRequestRef(url: URL(string: "https://github.com/\(repo)/pull/\(n)")!)!
}

private func entry(_ position: Int, _ number: Int, state: PullRequest.State = .open, draft: Bool = false,
                   mergeable: String = "MERGEABLE", review: String = "", checks: PullRequestStack.Entry.Checks = .passing) -> PullRequestStack.Entry {
    PullRequestStack.Entry(position: position, ref: ref(number), title: "Layer \(position)", state: state, isDraft: draft,
                           mergeable: mergeable, reviewDecision: review, checks: checks)
}

private let opened = Date(timeIntervalSince1970: 1_790_000_000)

private func pr(_ number: Int, base: String = "tokens-b", state: PullRequest.State = .open, draft: Bool = false) -> PullRequest {
    PullRequest(ref: ref(number), title: "t", state: state, isDraft: draft, author: .init(login: "octocat"),
                headRefName: "tokens-c", baseRefName: base, createdAt: opened, updatedAt: opened,
                mergeable: "MERGEABLE", mergeStateStatus: "CLEAN")
}

@Suite struct PullRequestStackParseTests {
    @Test func readsTheStackInPositionOrder() throws {
        let stack = try #require(try PullRequestStack.parse(Data(capturedStack.utf8)))
        #expect(stack.number == 457)
        #expect(stack.size == 4)
        #expect(stack.baseRefName == "trunk")
        #expect(stack.position == 3)
        #expect(stack.entries.map(\.position) == [1, 2, 3, 4])
        #expect(stack.entries.map(\.ref.number) == [450, 451, 452, 453])
        #expect(stack.below.map(\.ref.number) == [450, 451])
        #expect(stack.above.map(\.ref.number) == [453])
        #expect(stack.landsWith.map(\.ref.number) == [450, 451])
    }

    @Test func readsEachLayersFacts() throws {
        let e = try #require(try PullRequestStack.parse(Data(capturedStack.utf8))).entries
        #expect(e[0].isConflicting && e[0].checks == .passing)
        #expect(e[1].checks == .failing && e[1].headRefName == "tokens-b")
        #expect(e[2].checks == .none && e[2].reviewDecision == "APPROVED")
        #expect(e[3].isDraft && e[3].checks == .pending)
        #expect(e[0].ref.url.absoluteString == "https://github.com/octocat/example/pull/450")
    }

    @Test func noStackIsNil() throws {
        let json = #"{"data":{"repository":{"pullRequest":{"stackEntry":null,"stack":null}}}}"#
        #expect(try PullRequestStack.parse(Data(json.utf8)) == nil)
    }

    @Test func aMissingPullRequestThrows() {
        let json = #"{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND"}]}"#
        #expect(throws: GitHubError.self) { try PullRequestStack.parse(Data(json.utf8)) }
    }

    @Test func mergedLayersLandNothing() {
        let stack = PullRequestStack(number: 1, size: 3, baseRefName: "main", position: 3,
                                     entries: [entry(1, 1, state: .merged), entry(2, 2, state: .merged), entry(3, 3)])
        #expect(stack.landsWith.isEmpty)
        #expect(stack.isOpen)
    }

    @Test func aHostWithoutStacksIsRecognised() {
        let stderr = "gh: Field 'stack' doesn't exist on type 'PullRequest'"
        #expect(PullRequestStack.isUnsupported(stderr: stderr, stdout: Data()))
        #expect(PullRequestStack.isUnsupported(stderr: "", stdout: Data(#"{"errors":[{"extensions":{"code":"undefinedField"}}]}"#.utf8)))
        #expect(!PullRequestStack.isUnsupported(stderr: "gh: Could not resolve to a PullRequest", stdout: Data()))
    }

    @Test func aLayerWearsTheMarkItsPaneWould() {
        #expect(entry(1, 1, mergeable: "CONFLICTING", checks: .failing).mark.attention == .checksFailing)
        #expect(entry(1, 1, mergeable: "CONFLICTING").mark.attention == .conflicts)
        #expect(entry(1, 1, review: "CHANGES_REQUESTED", checks: .pending).mark.attention == .changesRequested)
        #expect(entry(1, 1, checks: .pending).mark.attention == .checksPending)
        #expect(entry(1, 1, review: "APPROVED").mark.summary == "Open · approved")
        #expect(entry(1, 1, draft: true, checks: .none).mark.summary == "Draft")
        #expect(entry(1, 1, state: .merged, checks: .failing).mark.attention == .none)
    }
}

@Suite struct PullRequestStackOrderTests {
    @Test func gathersAStackInPositionOrderWhereItsFirstMemberWas() {
        let stacks: [Int: Int] = [12: 2, 11: 1, 13: 3]   // number → position, all in stack 9
        let refs = [ref(5), ref(13), ref(20), ref(11), ref(12)]
        let ordered = PullRequestStack.ordered(refs) { r in
            stacks[r.number].map { PullRequestStack(number: 9, size: 3, baseRefName: "main", position: $0, entries: []) }
        }
        #expect(ordered.map(\.number) == [5, 11, 12, 13, 20])
    }

    @Test func sameStackNumberInAnotherRepositoryIsAnotherStack() {
        let refs = [ref(2, repo: "o/a"), ref(1, repo: "o/b"), ref(1, repo: "o/a")]
        let ordered = PullRequestStack.ordered(refs) { r in
            PullRequestStack(number: 1, size: 2, baseRefName: "main", position: r.number, entries: [])
        }
        #expect(ordered.map(\.url.absoluteString) == ["https://github.com/o/a/pull/1", "https://github.com/o/a/pull/2",
                                                      "https://github.com/o/b/pull/1"])
    }
}

@Suite struct PullRequestStackStatusTests {
    private func stack(position: Int = 3, _ entries: [PullRequestStack.Entry]) -> PullRequestStack {
        PullRequestStack(number: 457, size: 4, baseRefName: "trunk", position: position, entries: entries)
    }

    @Test func noStackChangesNothing() {
        let plain = PullRequestStatus(pr: pr(452), viewerLogin: "octocat")
        #expect(plain.canMerge && plain.canAutoMerge)
        #expect(!plain.lines.contains { $0.id.hasPrefix("stack") })
    }

    @Test func theStackLineSaysWhatLandsWithIt() {
        let s = stack([entry(1, 450), entry(2, 451), entry(3, 452), entry(4, 453)])
        let status = PullRequestStatus(pr: pr(452), viewerLogin: "octocat", stack: s)
        #expect(status.lines.first?.id == "stack")
        #expect(status.lines.first?.text == "Layer 3 of 4 in a stack onto trunk")
        #expect(status.lines.first?.detail == "Merging also lands #450 and #451")
        #expect(status.canMerge)
    }

    @Test func theStackLineSitsUnderDraft() {
        let status = PullRequestStatus(pr: pr(450, base: "trunk", draft: true), viewerLogin: "octocat",
                                       stack: stack(position: 1, [entry(1, 450, draft: true)]))
        #expect(status.lines.prefix(2).map(\.id) == ["draft", "stack"])
        #expect(status.lines[1].detail == "Bottom of the stack")
    }

    @Test func aDraftOrConflictBelowStopsTheMerge() {
        let drafts = PullRequestStatus(pr: pr(452), viewerLogin: "octocat",
                                       stack: stack([entry(1, 450, draft: true), entry(2, 451), entry(3, 452)]))
        #expect(!drafts.canMerge)
        #expect(drafts.mergeBlockedReason == "#450 below is still a draft")
        #expect(drafts.lines.contains { $0.id == "stack-draft" && $0.tone == .blocking })

        let conflicts = PullRequestStatus(pr: pr(452), viewerLogin: "octocat",
                                          stack: stack([entry(1, 450, mergeable: "CONFLICTING"), entry(2, 451, mergeable: "CONFLICTING"), entry(3, 452)]))
        #expect(!conflicts.canMerge)
        #expect(conflicts.mergeBlockedReason == "#450 and #451 below have conflicts")
    }

    @Test func failingChecksBelowReadAsBlockingButLeaveTheButton() {
        let status = PullRequestStatus(pr: pr(452), viewerLogin: "octocat",
                                       stack: stack([entry(1, 450, review: "CHANGES_REQUESTED"), entry(2, 451, checks: .failing), entry(3, 452)]))
        #expect(status.canMerge)
        #expect(status.lines.contains { $0.id == "stack-checks" && $0.text == "Checks failing on #451 below" })
        #expect(status.lines.contains { $0.id == "stack-review" && $0.tone == .blocking })
    }

    @Test func mergedLayersBelowAreNotBlockers() {
        let status = PullRequestStatus(pr: pr(452, base: "trunk"), viewerLogin: "octocat",
                                       stack: stack([entry(1, 450, state: .merged, draft: true), entry(2, 451, state: .merged, mergeable: "CONFLICTING"), entry(3, 452)]))
        #expect(status.canMerge)
        #expect(status.lines.first?.detail == "Every layer below has merged")
    }

    @Test func autoMergeIsOffInAStack() {
        let status = PullRequestStatus(pr: pr(452), viewerLogin: "octocat", stack: stack([entry(3, 452)]))
        #expect(status.canMerge && !status.canAutoMerge)
        #expect(status.autoMergeBlockedReason == "Auto-merge isn't available for stacked pull requests")
    }

    @Test func manyReferencesAreCut() {
        let entries = (1...5).map { entry($0, 100 + $0) }
        #expect(PullRequestStatus.references(entries) == "#101, #102, #103 +2 more")
    }
}

@Suite struct PullRequestStackRefreshTests {
    private let now = Date(timeIntervalSince1970: 1_790_001_000)

    @Test func firstReadFetchesTheStack() {
        #expect(PullRequestRefresh.needsStack(fresh: pr(452), cached: nil, stackFetchedAt: nil, now: now))
        #expect(PullRequestRefresh.needsStack(fresh: pr(452), cached: pr(452), stackFetchedAt: nil, now: now))
    }

    @Test func aFastReadDoesNotPayForIt() {
        #expect(!PullRequestRefresh.needsStack(fresh: pr(452), cached: pr(452), stackFetchedAt: now.addingTimeInterval(-15), now: now))
    }

    @Test func aRetargetOrStateChangeRereadsAtOnce() {
        let recent = now.addingTimeInterval(-5)
        #expect(PullRequestRefresh.needsStack(fresh: pr(452, base: "trunk"), cached: pr(452), stackFetchedAt: recent, now: now))
        #expect(PullRequestRefresh.needsStack(fresh: pr(452, state: .merged), cached: pr(452), stackFetchedAt: recent, now: now))
    }

    @Test func anOpenStackExpiresAndASettledOneDoesNot() {
        let old = now.addingTimeInterval(-PullRequestRefresh.stackTTL)
        #expect(PullRequestRefresh.needsStack(fresh: pr(452), cached: pr(452), stackFetchedAt: old, now: now))
        #expect(!PullRequestRefresh.needsStack(fresh: pr(452, state: .merged), cached: pr(452, state: .merged), stackFetchedAt: old, now: now))
    }
}

@Suite struct AsyncMergeTests {
    @Test func buildsTheReadAndMergeCalls() {
        let r = ref(452)
        let stack = GitHubService.arguments(for: .stack(r))
        #expect(stack.prefix(4) == ["api", "graphql", "--hostname", "github.com"])
        #expect(stack.contains("number=452") && stack.contains("owner=octocat") && stack.contains("repo=example"))
        #expect(GitHubService.arguments(for: .mergeAsync(r, .squash, sha: "abc123")) ==
                ["api", "--hostname", "github.com", "-X", "PUT", "repos/octocat/example/pulls/452/merge-async",
                 "-f", "merge_method=squash", "-f", "sha=abc123"])
        #expect(GitHubService.arguments(for: .mergeAsync(r, .rebase, sha: nil)).suffix(2) == ["-f", "merge_method=rebase"])
        #expect(GitHubService.arguments(for: .mergeAsyncResult(r, uuid: "u-1")) ==
                ["api", "--hostname", "github.com", "repos/octocat/example/pulls/452/merge-async/u-1"])
    }

    @Test func parsesEachShape() {
        let pending = #"{"status":"pending","details":{"message":"queued","uuid":"u-1","merge_method":"squash","merge_action":"default","expected_head_sha":"abc"}}"#
        #expect(AsyncMergeResult.parse(Data(pending.utf8)) == AsyncMergeResult(status: .pending, uuid: "u-1", message: "queued"))
        let merged = #"{"status":"merged","details":{"message":"Merged","sha":"def"}}"#
        #expect(AsyncMergeResult.parse(Data(merged.utf8))?.isFinished == true)
        #expect(AsyncMergeResult.parse(Data(#"{"message":"Pull Request is not mergeable","status":"400"}"#.utf8)) == nil)
    }

    @Test func pollsUntilItLands() async throws {
        let answers = Answers([.init(status: .pending, uuid: "u-1"), .init(status: .merged, message: "Merged")])
        let result = try await GitHubService.settle(.init(status: .pending, uuid: "u-1"), sleep: { _ in }) { uuid in
            #expect(uuid == "u-1")
            return await answers.next()
        }
        #expect(result.status == .merged)
        #expect(await answers.asked == 2)
    }

    @Test func aFinishedFirstAnswerIsNotPolled() async throws {
        let result = try await GitHubService.settle(.init(status: .enqueued), sleep: { _ in }) { _ in
            Issue.record("polled a finished merge"); return .init(status: .failed)
        }
        #expect(result.status == .enqueued)
    }

    @Test func givesUpAfterTheTimeout() async {
        await #expect(throws: GitHubError.self) {
            try await GitHubService.settle(.init(status: .pending, uuid: "u-1"), interval: .seconds(2), timeout: .seconds(6),
                                           sleep: { _ in }) { _ in .init(status: .pending, uuid: "u-1") }
        }
    }

    @Test func pendingWithoutAnIdThrows() async {
        await #expect(throws: GitHubError.self) {
            try await GitHubService.settle(.init(status: .pending), sleep: { _ in }) { _ in .init(status: .merged) }
        }
    }
}

private actor Answers {
    private var queue: [AsyncMergeResult]
    private(set) var asked = 0
    init(_ queue: [AsyncMergeResult]) { self.queue = queue }
    func next() -> AsyncMergeResult { asked += 1; return queue.removeFirst() }
}
