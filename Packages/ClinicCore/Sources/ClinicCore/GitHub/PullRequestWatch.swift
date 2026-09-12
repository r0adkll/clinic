import Foundation

/// What a watched pull request tells you, and when (ADR-128).
///
/// Pure, like [[PullRequestStatus]]: the *verdict* over a check rollup, the *transition* that is worth
/// a notification, and the words it is announced in. `PRStore` decides nothing here — it reads, calls
/// `completion`, and routes whatever comes back.
public enum PullRequestWatch {
    /// How a run of checks ended.
    public enum Verdict: Hashable, Sendable {
        case passed(count: Int)
        /// `first` names the failing job when exactly one failed, so the notification can say what broke.
        case failed(count: Int, first: String?)

        public var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    /// The verdict for a rollup as it stands, or nil while there is nothing to say: a check is still
    /// queued or running, or nothing ran at all.
    ///
    /// `cancelled` and `unknown` deliberately do not count as failures — the panel's own lines do not
    /// call them failing either ([[ADR-087 Pull Request Panel Is Status-First]]), and a notification
    /// that disagrees with the merge box on screen is worse than one that stays quiet.
    public static func verdict(for pr: PullRequest) -> Verdict? {
        guard !pr.checks.isEmpty else { return nil }
        guard !pr.hasPendingChecks else { return nil }
        let failed = pr.checks.filter { $0.status == .failure }
        guard failed.isEmpty else {
            return .failed(count: failed.count, first: failed.count == 1 ? failed[0].name : nil)
        }
        return .passed(count: pr.checks.count)
    }

    /// The verdict this read is worth announcing, or nil for silence.
    ///
    /// Three rules, and each exists because of a notification nobody wants:
    /// - **The first read of a pull request never announces anything.** Opening Clinic to a week-old
    ///   green build is not news, and without this every relaunch would replay it.
    /// - **Only a run that was seen in flight completes.** If the previous read already had a verdict,
    ///   this one is the same verdict again.
    /// - **Only on the commit that was being watched.** A head that moved between reads means these
    ///   checks belong to a commit whose run was never observed; the next completion on it will
    ///   announce itself properly.
    public static func completion(previous: PullRequest?, fresh: PullRequest) -> Verdict? {
        guard let previous else { return nil }
        guard previous.headRefOid == fresh.headRefOid else { return nil }
        guard verdict(for: previous) == nil else { return nil }
        return verdict(for: fresh)
    }

    /// The notification's body: what happened, on which pull request.
    public static func sentence(_ verdict: Verdict, host: CodeHost, number: Int) -> String {
        let reference = host.reference(number)
        return switch verdict {
        case .passed(let count):
            count == 1 ? "\(reference) · Check passed" : "\(reference) · All \(count) checks passed"
        case .failed(_, .some(let name)):
            "\(reference) · \(name) failed"
        case .failed(let count, nil):
            "\(reference) · \(count) checks failed"
        }
    }
}
