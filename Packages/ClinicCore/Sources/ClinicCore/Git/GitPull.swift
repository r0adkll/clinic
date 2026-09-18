import Foundation

/// What a `git pull --ff-only` brought in (ADR-165): the branch and its upstream, where HEAD moved,
/// the commits that arrived and their line totals.
public struct GitPullReport: Sendable, Hashable {
    public var branch: String
    public var upstream: String
    /// HEAD before the pull; nil on a branch with no commits yet.
    public var from: String?
    public var to: String?
    /// Newest first, at most the limit `pullReport` was given.
    public var commits: [GitCommit]
    /// Every commit that arrived, which can exceed `commits.count`.
    public var commitCount: Int
    public var stat: DiffStat

    public var isUpToDate: Bool { from == to }

    public init(branch: String, upstream: String, from: String?, to: String?, commits: [GitCommit] = [], commitCount: Int = 0, stat: DiffStat = DiffStat()) {
        self.branch = branch
        self.upstream = upstream
        self.from = from
        self.to = to
        self.commits = commits
        self.commitCount = commitCount
        self.stat = stat
    }
}

/// Why a pull did not happen, read from git's stderr (which `GitProcess` runs under the C locale, so
/// the wording is git's English). `.other` keeps git's own output as the only explanation.
public enum GitPullFailure: Sendable, Hashable {
    case detachedHead
    case noUpstream(branch: String)
    /// The upstream the branch tracks was not fetched: usually deleted on the remote after a merge.
    case upstreamGone(branch: String, upstream: String?)
    /// Local commits the upstream lacks, so `--ff-only` refuses. `ahead`/`behind` are filled in after the fact.
    case diverged(ahead: Int?, behind: Int?)
    /// Uncommitted edits to files the pull would change.
    case localChanges(files: [String])
    /// Untracked files where the pull would write tracked ones.
    case untrackedFiles(files: [String])
    case authentication
    case network
    case other

    /// Classifies git's stderr from a failed `git pull --ff-only`.
    public static func classify(_ stderr: String, branch: String = "") -> GitPullFailure {
        let s = stderr
        func has(_ needle: String) -> Bool { s.range(of: needle, options: .caseInsensitive) != nil }
        if has("You are not currently on a branch") { return .detachedHead }
        if has("There is no tracking information for the current branch") { return .noUpstream(branch: branch) }
        if has("but no such ref was fetched") {
            // "Your configuration specifies to merge with the ref 'refs/heads/x'\nfrom the remote, but no such ref was fetched."
            var upstream: String?
            if let r = s.range(of: "merge with the ref '"), let end = s[r.upperBound...].firstIndex(of: "'") {
                upstream = String(s[r.upperBound..<end]).replacingOccurrences(of: "refs/heads/", with: "")
            }
            return .upstreamGone(branch: branch, upstream: upstream)
        }
        if has("Not possible to fast-forward") || has("Diverging branches can't be fast-forwarded") { return .diverged(ahead: nil, behind: nil) }
        if has("untracked working tree files would be overwritten") { return .untrackedFiles(files: listedFiles(s, after: "would be overwritten")) }
        if has("Your local changes to the following files would be overwritten") { return .localChanges(files: listedFiles(s, after: "would be overwritten")) }
        if has("cannot pull with rebase") || has("You have unstaged changes") || has("Your index contains uncommitted changes") { return .localChanges(files: []) }
        if has("Authentication failed") || has("Permission denied") || has("could not read Username") || has("could not read Password")
            || has("terminal prompts disabled") || has("Host key verification failed") || has("returned error: 403") || has("returned error: 401") { return .authentication }
        if has("Could not resolve host") || has("unable to access") || has("Connection timed out") || has("Connection refused")
            || has("Operation timed out") || has("Network is unreachable") || has("Could not read from remote repository") { return .network }
        return .other
    }

    /// The tab-indented paths git lists under a "…would be overwritten…:" line.
    static func listedFiles(_ s: String, after marker: String) -> [String] {
        var files: [String] = [], inList = false
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if !inList { inList = line.contains(marker); continue }
            guard line.hasPrefix("\t") else { break }
            let path = line.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { files.append(path) }
        }
        return files
    }
}

/// A pull that did not happen: the reason, and git's own words for the details disclosure.
public struct GitPullError: Error, Sendable, Hashable {
    public var failure: GitPullFailure
    public var branch: String?
    public var upstream: String?
    public var output: String

    public init(failure: GitPullFailure, branch: String? = nil, upstream: String? = nil, output: String = "") {
        self.failure = failure
        self.branch = branch
        self.upstream = upstream
        self.output = output
    }
}

extension GitRepository {
    /// `git pull --ff-only` (ADR-065), reported as what arrived rather than git's stdout (ADR-165).
    /// Throws `GitPullError`; the branch and upstream are checked first so the two commonest refusals
    /// never touch the network.
    public func pullReport(commitLimit: Int = 50) async throws(GitPullError) -> GitPullReport {
        guard let branch = await currentBranch() else { throw GitPullError(failure: .detachedHead) }
        let up = await GitProcess.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: root)
        let upstream = up.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard up.status == 0, !upstream.isEmpty else {
            throw GitPullError(failure: .noUpstream(branch: branch), branch: branch, output: up.stderr)
        }
        let before = await revParse("HEAD")
        let pull = await GitProcess.run(["pull", "--ff-only", "--no-rebase"], in: root)
        guard pull.status == 0 else {
            var failure = GitPullFailure.classify(pull.stderr, branch: branch)
            if case .diverged = failure {
                let counts = await GitProcess.run(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: root)
                let n = counts.stdoutString.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
                failure = .diverged(ahead: n.count == 2 ? n[0] : nil, behind: n.count == 2 ? n[1] : nil)
            }
            let output = [pull.stdoutString, pull.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
            throw GitPullError(failure: failure, branch: branch, upstream: upstream, output: output)
        }
        let after = await revParse("HEAD")
        var report = GitPullReport(branch: branch, upstream: upstream, from: before, to: after)
        guard let after, before != after else { return report }
        // A first pull onto an unborn branch has no `before`: everything reachable arrived.
        let range = before.map { "\($0)..\(after)" } ?? after
        let count = await GitProcess.run(["rev-list", "--count", range], in: root)
        report.commitCount = Int(count.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let log = await GitProcess.run(["log", "--no-color", "--format=%H%x1f%h%x1f%an%x1f%aI%x1f%s", "-n", String(max(commitLimit, 1)), range], in: root)
        report.commits = Self.parseCommits(log.stdoutString)
        if let before {
            let stat = await GitProcess.run(["diff", "--numstat", "--no-color", before, after], in: root)
            report.stat = DiffStat(numstat: stat.stdoutString)
        }
        return report
    }

    private func revParse(_ ref: String) async -> String? {
        let r = await GitProcess.run(["rev-parse", "--verify", "-q", ref], in: root)
        let sha = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !sha.isEmpty ? sha : nil
    }
}
