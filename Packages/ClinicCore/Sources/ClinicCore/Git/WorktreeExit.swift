import Foundation

/// What Clinic presses when the CLI asks, as a worktree session exits, what to do with its worktree
/// (ADR-190). The dialog appears before `SessionEnd`, so a close that waits for the hook never ends
/// until someone answers it.
public enum WorktreeExitAnswer: String, Codable, Sendable, CaseIterable {
    /// Press *1. Keep worktree*: the directory and branch stay. The default.
    case keep
    /// Press *2. Remove worktree*: the CLI deletes the directory and its branch, uncommitted work included.
    case remove
    /// Decide per close, in Clinic's own sheet, before the CLI is asked to exit.
    case ask

    public static let preferenceKey = "ClinicWorktreeExitAnswer"

    /// The digit the dialog takes. A bare key press both selects and confirms (checked against
    /// CLI 2.1.295: `2` alone removed the worktree and its branch).
    public var digit: Character? {
        switch self {
        case .keep: "1"
        case .remove: "2"
        case .ask: nil
        }
    }
}

/// The CLI's *Exiting worktree session* dialog, as it reads off the terminal grid.
public enum WorktreeExitDialog {
    /// Whether the text shows the dialog still waiting for an answer. Whitespace is ignored on both
    /// sides: Ink lays the dialog out with cursor moves, so a read of the grid can carry its gaps
    /// differently from the source text, and a wrapped path can split a word.
    public static func isShowing(in text: String) -> Bool {
        let flat = text.filter { !$0.isWhitespace }
        guard let start = flat.range(of: "Exitingworktreesession", options: .backwards)?.upperBound else { return false }
        let rest = flat[start...]
        guard rest.contains("Keepworktree"), rest.contains("Removeworktree"), rest.contains("Entertoconfirm") else { return false }
        return !rest.contains("Keepingworktree") && !rest.contains("Removingworktree") && !rest.contains("Worktreeremoved")
    }
}

/// What removing a worktree would lose, read before the session is asked to exit, so Clinic's own
/// sheet can say it and the answer can be given in advance (ADR-190).
public struct WorktreeExitFacts: Equatable, Sendable {
    /// `<repo>/.claude/worktrees/<name>`.
    public var path: String
    public var branch: String?
    public var uncommittedFiles: Int
    /// Commits on the worktree's branch that the repository's default branch lacks.
    public var commits: Int
    /// Git could not be read: the counts are unknown, not zero.
    public var unverified: Bool

    public init(path: String, branch: String? = nil, uncommittedFiles: Int = 0, commits: Int = 0, unverified: Bool = false) {
        self.path = path; self.branch = branch; self.uncommittedFiles = uncommittedFiles; self.commits = commits; self.unverified = unverified
    }

    public var name: String { (path as NSString).lastPathComponent }
    /// Nothing would be lost. The CLI removes a clean worktree itself when the session is unnamed.
    public var isClean: Bool { !unverified && uncommittedFiles == 0 && commits == 0 }

    /// The worktree root a session's directory lies in, or nil when it is not under `.claude/worktrees/`.
    public static func worktreeRoot(forCwd cwd: String) -> String? {
        guard let r = cwd.range(of: "/.claude/worktrees/") else { return nil }
        let rest = cwd[r.upperBound...]
        guard let name = rest.split(separator: "/", omittingEmptySubsequences: true).first, !name.isEmpty else { return nil }
        return String(cwd[..<r.upperBound]) + name
    }

    /// One sentence of what is in the worktree: *It holds 2 uncommitted files and 1 commit of its own on worktree-x.*
    public var summary: String {
        if unverified { return "Clinic could not read what the worktree holds." }
        let branchPart = branch.map { " on \($0)" } ?? ""
        if isClean { return "The worktree is clean: nothing in it would be lost." }
        var parts: [String] = []
        if uncommittedFiles > 0 { parts.append("\(uncommittedFiles) uncommitted file\(uncommittedFiles == 1 ? "" : "s")") }
        if commits > 0 { parts.append("\(commits) commit\(commits == 1 ? "" : "s") of its own\(branchPart)") }
        return "It holds " + parts.joined(separator: " and ") + "."
    }
}

extension GitRepository {
    /// Reads the facts for the worktree at `path`, which must be a checkout of this repository.
    public static func worktreeExitFacts(at path: String) async -> WorktreeExitFacts {
        let wt = GitRepository(root: path)
        guard let status = try? await wt.status() else { return WorktreeExitFacts(path: path, unverified: true) }
        var facts = WorktreeExitFacts(path: path, branch: status.branch, uncommittedFiles: status.files.count)
        if let base = await wt.defaultBranch(), base != status.branch {
            let r = await GitProcess.run(["rev-list", "--count", "\(base)..HEAD"], in: path)
            if r.status == 0 { facts.commits = Int(r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        }
        return facts
    }
}
