import Foundation
import Testing
@testable import ClinicCore

/// When the PR panel re-reads a pull request, and what that read has to fetch (ADR-127). Pure policy,
/// so the cadence is covered here rather than by watching the panel with a stopwatch.
@Suite struct PullRequestRefreshTests {
    let ref = PullRequestRef(url: URL(string: "https://github.com/octocat/example/pull/42")!)!
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func check(_ name: String, _ status: PullRequest.Check.Status) -> PullRequest.Check {
        PullRequest.Check(id: name, name: name, status: status)
    }

    private func comment(_ id: String, body: String) -> PullRequest.Comment {
        PullRequest.Comment(id: id, kind: .comment, author: .init(login: "octocat"), body: body, createdAt: now)
    }

    private func pr(state: PullRequest.State = .open, mergeable: String = "MERGEABLE",
                    mergeStateStatus: String = "CLEAN", checks: [PullRequest.Check] = [],
                    body: String = "ship it", comments: [PullRequest.Comment] = []) -> PullRequest {
        PullRequest(ref: ref, title: "Ship it", body: body, state: state, author: .init(login: "octocat"),
                    headRefName: "feature", baseRefName: "main", createdAt: now, updatedAt: now,
                    mergeable: mergeable, mergeStateStatus: mergeStateStatus, checks: checks, comments: comments)
    }

    // MARK: Cadence

    @Test func nothingCachedIsDueImmediately() {
        #expect(PullRequestRefresh.interval(for: nil, isFront: false, appActive: false) == .zero)
    }

    @Test func aSettledPullRequestLeavesThePoll() {
        #expect(PullRequestRefresh.interval(for: pr(state: .merged), isFront: true, appActive: true) == nil)
        #expect(PullRequestRefresh.interval(for: pr(state: .closed), isFront: true, appActive: true) == nil)
    }

    @Test func runningChecksOnScreenPollFast() {
        let running = pr(checks: [check("build", .success), check("test", .pending)])
        #expect(PullRequestRefresh.interval(for: running, isFront: true, appActive: true) == PullRequestRefresh.watching)
    }

    /// GitHub reports `UNKNOWN` while it is still working out whether a PR merges — which happens
    /// right after a push, exactly when the reader is watching.
    @Test func unknownMergeabilityPollsFast() {
        #expect(PullRequestRefresh.interval(for: pr(mergeable: "UNKNOWN"), isFront: true, appActive: true)
                == PullRequestRefresh.watching)
        #expect(PullRequestRefresh.interval(for: pr(mergeStateStatus: "UNKNOWN"), isFront: true, appActive: true)
                == PullRequestRefresh.watching)
    }

    @Test func settledChecksOnScreenPollAtTheMinute() {
        let green = pr(checks: [check("build", .success), check("skipped", .skipped)])
        #expect(PullRequestRefresh.interval(for: green, isFront: true, appActive: true) == PullRequestRefresh.foreground)
    }

    /// A pane behind another one, or the whole app in the background, keeps ADR-053's five minutes —
    /// including when checks are running, which is the case that would otherwise poll hardest for
    /// nobody's benefit.
    @Test func offScreenAndInactiveBackOff() {
        let running = pr(checks: [check("test", .pending)])
        #expect(PullRequestRefresh.interval(for: running, isFront: false, appActive: true) == PullRequestRefresh.background)
        #expect(PullRequestRefresh.interval(for: running, isFront: true, appActive: false) == PullRequestRefresh.background)
    }

    // MARK: Rendered HTML

    @Test func firstReadFetchesTheRendering() {
        #expect(PullRequestRefresh.needsRenderedHTML(fresh: pr(), cached: nil, htmlFetchedAt: nil, now: now))
        #expect(PullRequestRefresh.needsRenderedHTML(fresh: pr(), cached: pr(), htmlFetchedAt: nil, now: now))
    }

    /// The whole point of ADR-127's split: a check finishing must not cost a GraphQL round trip.
    @Test func aFinishedCheckDoesNotReFetchTheRendering() {
        let before = pr(checks: [check("build", .pending)])
        let after = pr(checks: [check("build", .success)])
        #expect(!PullRequestRefresh.needsRenderedHTML(fresh: after, cached: before,
                                                      htmlFetchedAt: now.addingTimeInterval(-30), now: now))
    }

    @Test func aNewCommentReFetchesTheRendering() {
        let before = pr(comments: [comment("c1", body: "first")])
        let after = pr(comments: [comment("c1", body: "first"), comment("c2", body: "second")])
        #expect(PullRequestRefresh.needsRenderedHTML(fresh: after, cached: before,
                                                     htmlFetchedAt: now.addingTimeInterval(-30), now: now))
    }

    @Test func anEditedBodyReFetchesTheRendering() {
        #expect(PullRequestRefresh.needsRenderedHTML(fresh: pr(body: "edited"), cached: pr(body: "ship it"),
                                                     htmlFetchedAt: now.addingTimeInterval(-30), now: now))
    }

    /// The image URLs GitHub signs into the rendering expire after five minutes (ADR-090), so it is
    /// re-fetched inside that window even when nothing was written.
    @Test func theRenderingIsReFetchedBeforeItsImagesExpire() {
        let fresh = now.addingTimeInterval(-PullRequestRefresh.renderedHTMLTTL + 10)
        let stale = now.addingTimeInterval(-PullRequestRefresh.renderedHTMLTTL)
        #expect(!PullRequestRefresh.needsRenderedHTML(fresh: pr(), cached: pr(), htmlFetchedAt: fresh, now: now))
        #expect(PullRequestRefresh.needsRenderedHTML(fresh: pr(), cached: pr(), htmlFetchedAt: stale, now: now))
        #expect(PullRequestRefresh.renderedHTMLTTL < 300)
    }

    // MARK: Ref updates

    @Test func aPushIsARefUpdate() {
        #expect(PullRequestRefresh.isRefUpdate(path: "/repo/.git/refs/remotes/origin/feature"))
        #expect(PullRequestRefresh.isRefUpdate(path: "/repo/.git/logs/refs/remotes/origin/feature"))
        #expect(PullRequestRefresh.isRefUpdate(path: "/repo/.git/packed-refs"))
    }

    /// Everything a turn writes into the git directory that says nothing about the remote. `FETCH_HEAD`
    /// is in here on purpose: a plain `git fetch` writes it whether or not anything moved.
    @Test func localGitTrafficIsNotARefUpdate() {
        for path in ["/repo/.git/index", "/repo/.git/HEAD", "/repo/.git/logs/HEAD", "/repo/.git/ORIG_HEAD",
                     "/repo/.git/refs/heads/feature", "/repo/.git/FETCH_HEAD", "/repo/.git/COMMIT_EDITMSG"] {
            #expect(!PullRequestRefresh.isRefUpdate(path: path), "\(path)")
        }
    }

    // MARK: What a pull request is waiting for

    @Test func awaitingResultOnlyAppliesToOpenPullRequests() {
        #expect(pr(checks: [check("test", .pending)]).isAwaitingResult)
        #expect(!pr(state: .merged, mergeable: "UNKNOWN", checks: [check("test", .pending)]).isAwaitingResult)
        #expect(!pr(checks: [check("test", .success)]).isAwaitingResult)
        #expect(pr(state: .merged).isSettled && !pr().isSettled)
    }
}
