import Foundation

/// The kind of change git reports for one side (index or worktree) of a path.
public enum GitChangeKind: String, Sendable, Hashable {
    case modified, added, deleted, renamed, copied, typeChanged, unmerged, untracked

    /// Maps a porcelain-v2 status letter (`M`, `A`, `D`, `R`, `C`, `T`, `U`); `.` and unknown letters yield nil.
    init?(porcelainLetter c: Character) {
        switch c {
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .unmerged
        default: return nil
        }
    }
}

/// One path from `git status`, with its staged (index) and unstaged (worktree) change kinds.
public struct GitFileStatus: Identifiable, Hashable, Sendable {
    /// Repo-relative path; the new path for renames and copies.
    public var path: String
    /// Original path for renames and copies.
    public var oldPath: String?
    /// Staged change, nil if none.
    public var index: GitChangeKind?
    /// Unstaged change, nil if none (`.untracked` for untracked files).
    public var worktree: GitChangeKind?
    public var isConflicted: Bool

    public init(path: String, oldPath: String? = nil, index: GitChangeKind? = nil, worktree: GitChangeKind? = nil, isConflicted: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.index = index
        self.worktree = worktree
        self.isConflicted = isConflicted
    }

    public var id: String { path }
    public var isUntracked: Bool { worktree == .untracked }
    public var hasStagedChanges: Bool { index != nil }
    public var hasUnstagedChanges: Bool { worktree != nil }
}

public struct GitCommit: Identifiable, Hashable, Sendable {
    public var sha: String
    public var shortSha: String
    public var author: String
    public var date: Date
    public var subject: String

    public init(sha: String, shortSha: String, author: String, date: Date, subject: String) {
        self.sha = sha
        self.shortSha = shortSha
        self.author = author
        self.date = date
        self.subject = subject
    }

    public var id: String { sha }
}

/// Result of `git status --porcelain=v2 --branch`.
public struct GitStatusSnapshot: Sendable, Equatable {
    /// Current branch name; nil when detached or unknown.
    public var branch: String?
    /// Upstream ref (e.g. `origin/main`), nil when none is configured.
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var files: [GitFileStatus]
    public var isDetached: Bool

    public init(branch: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, files: [GitFileStatus] = [], isDetached: Bool = false) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.isDetached = isDetached
    }
}

/// A git subprocess exited non-zero (or could not be launched).
public struct GitError: Error, CustomStringConvertible, Sendable {
    /// The git arguments that ran, joined with spaces (without the leading `git -C <root>`).
    public var command: String
    public var exitCode: Int32
    public var stderr: String
    public var description: String

    public init(command: String, exitCode: Int32, stderr: String, description: String? = nil) {
        self.command = command
        self.exitCode = exitCode
        self.stderr = stderr
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description ?? "git \(command) exited with \(exitCode)" + (trimmed.isEmpty ? "" : ": \(trimmed)")
    }
}

/// `git diff --numstat` totals. Binary files count as changed but contribute no lines (git writes `-`).
public struct DiffStat: Sendable, Hashable {
    public var files: Int
    public var additions: Int
    public var deletions: Int

    public init(files: Int = 0, additions: Int = 0, deletions: Int = 0) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }

    public init(numstat: String) {
        var stat = DiffStat()
        for line in numstat.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2)
            guard f.count == 3 else { continue }
            stat.files += 1
            stat.additions += Int(f[0]) ?? 0
            stat.deletions += Int(f[1]) ?? 0
        }
        self = stat
    }

    public var isEmpty: Bool { files == 0 }
}
