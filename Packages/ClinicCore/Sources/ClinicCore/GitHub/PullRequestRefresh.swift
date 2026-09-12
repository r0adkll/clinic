import Foundation

/// When the pull request panel re-reads a pull request, and what that read has to fetch (ADR-127).
///
/// Pure policy over a `PullRequest`, so the cadence is a unit test rather than a stopwatch held to
/// the panel. `PRStore` owns the timer, the watcher and the `gh` calls; every *decision* about
/// whether a read is due lives here.
public enum PullRequestRefresh {
    /// On screen with a result still coming: checks running, or GitHub still computing mergeability.
    public static let watching: Duration = .seconds(15)
    /// On screen and settled. Comments and reviews still arrive from other people.
    public static let foreground: Duration = .seconds(60)
    /// Watched (ADR-128) with a result still coming, but nobody looking at it: fast enough that the
    /// notification arrives while the reader still cares, slow enough to be running in the background.
    public static let watched: Duration = .seconds(30)
    /// Open in a pane nobody is looking at, or the whole app in the background. ADR-053's cadence.
    public static let background: Duration = .seconds(300)

    /// A pane coming back to the front re-reads a pull request older than this rather than showing
    /// yesterday's answer while the timer runs down.
    public static let staleOnReturn: TimeInterval = 20

    /// GitHub signs the image URLs it embeds in rendered HTML and they expire after five minutes
    /// (ADR-090), so the rendering is re-fetched a little inside that window — but only on a read
    /// that is already due, and never on a fast one whose whole job is the check rollup.
    public static let renderedHTMLTTL: TimeInterval = 240

    /// How long after a push to look again. GitHub creates a commit's check runs asynchronously, so
    /// the read that fires the moment `refs/remotes/…` moves usually finds no checks at all; this
    /// second look is what turns the panel green-and-spinning instead of empty.
    public static let pushSettle: Duration = .seconds(8)

    /// The interval for one pull request, or nil when it will never change again.
    ///
    /// - Parameters:
    ///   - pr: the cached pull request; nil means nothing is known yet and the caller should fetch.
    ///   - isFront: its pane is the one on screen, in the selected tab of the active window.
    ///   - appActive: Clinic is the active application.
    ///   - isWatched: the reader asked to be told how this one ends (ADR-128), so it never drops to
    ///     the background cadence — a watch nobody polls is a watch that reports the news late.
    public static func interval(for pr: PullRequest?, isFront: Bool, appActive: Bool,
                                isWatched: Bool = false) -> Duration? {
        guard let pr else { return .zero }
        guard !pr.isSettled else { return nil }
        if isFront, appActive { return pr.isAwaitingResult ? watching : foreground }
        guard isWatched else { return background }
        return pr.isAwaitingResult ? watched : foreground
    }

    /// Whether a read that has just landed is due for GitHub's rendering of the bodies too (ADR-090).
    ///
    /// A fast poll over a running build must not pay for the GraphQL call, and must not blank the
    /// timeline either — `PRStore` re-applies the rendering it already has. This says when that
    /// cached rendering is no longer good enough: nothing cached, the signed image URLs are near
    /// expiry, or the bodies actually changed.
    public static func needsRenderedHTML(fresh: PullRequest, cached: PullRequest?,
                                         htmlFetchedAt: Date?, now: Date = Date()) -> Bool {
        guard let cached, let htmlFetchedAt else { return true }
        if now.timeIntervalSince(htmlFetchedAt) >= renderedHTMLTTL { return true }
        return bodySignature(fresh) != bodySignature(cached)
    }

    /// Everything the rendered HTML covers, and nothing that changes on its own: a new comment, an
    /// edited body or a deleted review makes this differ, a finished check does not.
    static func bodySignature(_ pr: PullRequest) -> [String] {
        [pr.body] + pr.comments.map { "\($0.id)\u{1}\($0.body)" }
    }

    /// Whether a path inside a repository's git directory means a ref moved — which is what a push
    /// looks like from the outside: `refs/remotes/<remote>/<branch>`, its reflog under
    /// `logs/refs/remotes/…`, or the whole lot packed away.
    ///
    /// `FETCH_HEAD` is deliberately not in here: a plain `git fetch` writes it without anything
    /// having moved, and a fetch that *did* move a remote-tracking ref writes that ref as well.
    public static func isRefUpdate(path: String) -> Bool {
        path.contains("/refs/remotes/") || path.hasSuffix("/packed-refs")
    }
}

public extension PullRequest {
    /// Merged or closed: nothing about it will change again, so it leaves the poll.
    var isSettled: Bool { state != .open }

    /// A check is queued or running.
    var hasPendingChecks: Bool { checks.contains { $0.status == .pending } }

    /// Something is still being computed on GitHub's side, so the next read will probably differ:
    /// a check is in flight, or GitHub has not finished working out whether this merges.
    var isAwaitingResult: Bool {
        guard state == .open else { return false }
        return hasPendingChecks || mergeable == "UNKNOWN" || mergeStateStatus == "UNKNOWN"
    }
}
