import Foundation
import Testing
@testable import ClinicCore

/// What a watched pull request announces, and — mostly — what it stays quiet about (ADR-128).
@Suite struct PullRequestWatchTests {
    let ref = PullRequestRef(url: URL(string: "https://github.com/octocat/example/pull/42")!)!
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func check(_ name: String, _ status: PullRequest.Check.Status) -> PullRequest.Check {
        PullRequest.Check(id: name, name: name, status: status)
    }

    /// Mergeability is settled unless a test says otherwise: `UNKNOWN` is itself a reason to poll fast
    /// (ADR-127), and these tests are about the checks.
    private func pr(state: PullRequest.State = .open, head: String? = "abc123",
                    checks: [PullRequest.Check] = []) -> PullRequest {
        PullRequest(ref: ref, title: "Ship it", state: state, author: .init(login: "octocat"),
                    headRefName: "feature", baseRefName: "main", headRefOid: head,
                    createdAt: now, updatedAt: now, mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
                    checks: checks)
    }

    // MARK: Verdict

    @Test func aRunInFlightHasNoVerdict() {
        #expect(PullRequestWatch.verdict(for: pr(checks: [check("build", .success), check("test", .pending)])) == nil)
        #expect(PullRequestWatch.verdict(for: pr(checks: [])) == nil)
    }

    @Test func everythingGreenPasses() {
        #expect(PullRequestWatch.verdict(for: pr(checks: [check("build", .success), check("lint", .skipped)]))
                == .passed(count: 2))
    }

    @Test func oneFailureNamesTheJob() {
        #expect(PullRequestWatch.verdict(for: pr(checks: [check("build", .failure), check("lint", .success)]))
                == .failed(count: 1, first: "build"))
    }

    @Test func severalFailuresAreCounted() {
        let v = PullRequestWatch.verdict(for: pr(checks: [check("build", .failure), check("test", .failure)]))
        #expect(v == .failed(count: 2, first: nil))
        #expect(v?.isFailure == true)
    }

    /// Cancelled and neutral runs are not failures here because they are not failures in the merge box
    /// either (ADR-087); a notification contradicting what is on screen is worse than a quiet one.
    @Test func cancelledIsNotCalledAFailure() {
        #expect(PullRequestWatch.verdict(for: pr(checks: [check("build", .success), check("test", .cancelled)]))
                == .passed(count: 2))
    }

    // MARK: What is worth saying

    /// Opening Clinic onto a week-old green build is not news. Without this, every relaunch would
    /// replay the last verdict of every watched pull request.
    @Test func theFirstReadAnnouncesNothing() {
        #expect(PullRequestWatch.completion(previous: nil, fresh: pr(checks: [check("build", .success)])) == nil)
    }

    @Test func aRunCompletingIsAnnouncedOnce() {
        let running = pr(checks: [check("build", .pending)])
        let done = pr(checks: [check("build", .success)])
        #expect(PullRequestWatch.completion(previous: running, fresh: done) == .passed(count: 1))
        // The same verdict, read again a minute later, says nothing.
        #expect(PullRequestWatch.completion(previous: done, fresh: done) == nil)
    }

    @Test func aFailureIsAnnounced() {
        let running = pr(checks: [check("build", .pending), check("test", .success)])
        let done = pr(checks: [check("build", .failure), check("test", .success)])
        #expect(PullRequestWatch.completion(previous: running, fresh: done) == .failed(count: 1, first: "build"))
    }

    /// A head that moved between reads means these checks belong to a commit whose run was never seen
    /// in flight. Staying quiet costs one notification; announcing would risk reporting the *old*
    /// commit's verdict against the new one.
    @Test func aNewCommitWaitsForItsOwnRun() {
        let running = pr(head: "abc123", checks: [check("build", .pending)])
        let pushed = pr(head: "def456", checks: [check("build", .success)])
        #expect(PullRequestWatch.completion(previous: running, fresh: pushed) == nil)
        // ...and the next completion on the new commit is announced normally.
        let pushedRunning = pr(head: "def456", checks: [check("build", .pending)])
        #expect(PullRequestWatch.completion(previous: pushedRunning, fresh: pushed) == .passed(count: 1))
    }

    /// Re-running a job on the same commit goes back in flight, so its second ending is news again.
    @Test func aReRunIsAnnouncedAgain() {
        let failed = pr(checks: [check("build", .failure)])
        let rerunning = pr(checks: [check("build", .pending)])
        let green = pr(checks: [check("build", .success)])
        #expect(PullRequestWatch.completion(previous: failed, fresh: rerunning) == nil)
        #expect(PullRequestWatch.completion(previous: rerunning, fresh: green) == .passed(count: 1))
    }

    // MARK: Words

    @Test func theSentenceSaysWhatHappened() {
        let host = ref.codeHost
        #expect(PullRequestWatch.sentence(.passed(count: 1), host: host, number: 42) == "#42 · Check passed")
        #expect(PullRequestWatch.sentence(.passed(count: 5), host: host, number: 42) == "#42 · All 5 checks passed")
        #expect(PullRequestWatch.sentence(.failed(count: 1, first: "build"), host: host, number: 42) == "#42 · build failed")
        #expect(PullRequestWatch.sentence(.failed(count: 3, first: nil), host: host, number: 42) == "#42 · 3 checks failed")
    }

    // MARK: Cadence

    /// The point of a watch: it keeps being read while the reader is looking at something else. Without
    /// this it would sit on ADR-127's five-minute background tier and report the news late.
    @Test func aWatchedPullRequestDoesNotFallToTheBackgroundTier() {
        let running = pr(checks: [check("build", .pending)])
        #expect(PullRequestRefresh.interval(for: running, isFront: false, appActive: false, isWatched: true)
                == PullRequestRefresh.watched)
        #expect(PullRequestRefresh.interval(for: running, isFront: false, appActive: false, isWatched: false)
                == PullRequestRefresh.background)
        // On screen it is still the fastest tier: watching never makes the panel slower.
        #expect(PullRequestRefresh.interval(for: running, isFront: true, appActive: true, isWatched: true)
                == PullRequestRefresh.watching)
        // Settled checks on a watched PR wait for the next run at the ordinary rate.
        #expect(PullRequestRefresh.interval(for: pr(checks: [check("build", .success)]), isFront: false,
                                            appActive: false, isWatched: true) == PullRequestRefresh.foreground)
        // And a merged one is never read again, watch or no watch.
        #expect(PullRequestRefresh.interval(for: pr(state: .merged), isFront: false, appActive: false,
                                            isWatched: true) == nil)
    }
}
