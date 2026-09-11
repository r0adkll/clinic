import Foundation

/// Where a new session's worktree branches from (ADR-118).
///
/// The CLI's `-w` knows two bases, named by its `worktree.baseRef` setting: `fresh`, the remote's
/// default branch (`origin/HEAD`, fetched when stale), and `head`, the launch directory's `HEAD`. It
/// takes no branch name. For `.branch`, Clinic creates the worktree itself and `-w <name>` adopts the
/// directory it finds there, at the tip Clinic gave it.
public enum WorktreeBase: Hashable, Sendable, Codable, RawRepresentable {
    case defaultBranch
    case currentBranch
    /// A local branch (`develop`) or a remote-tracking one (`origin/develop`), exactly as git names it.
    case branch(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "default": self = .defaultBranch
        case "current": self = .currentBranch
        default:
            let ref = rawValue.hasPrefix("branch:") ? String(rawValue.dropFirst(7)) : ""
            guard !ref.isEmpty else { return nil }
            self = .branch(ref)
        }
    }

    public var rawValue: String {
        switch self {
        case .defaultBranch: "default"
        case .currentBranch: "current"
        case .branch(let ref): "branch:" + ref
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let base = WorktreeBase(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown worktree base \(raw)"))
        }
        self = base
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// The `worktree.baseRef` a launch carries. Always explicit, so a `baseRef` in the user's own
    /// settings can't change what the composer said would happen. A named branch uses `head`: the
    /// CLI documents that a reused worktree is never reset to the default branch under `head`.
    public var cliBaseRef: String { self == .defaultBranch ? "fresh" : "head" }

    /// True when Clinic, not the CLI, has to create the worktree.
    public var createsWorktree: Bool {
        if case .branch = self { return true }
        return false
    }
}

/// What launching a worktree session from a named branch takes (ADR-118). Pure, so the naming and the
/// reuse rule are tested without a repository.
public struct WorktreePlan: Equatable, Sendable {
    /// `-w <name>`.
    public var name: String
    /// `<repo>/.claude/worktrees/<name>`, where the CLI looks for it.
    public var path: String
    /// `worktree-<name>`, the CLI's own spelling for the branches it creates.
    public var branch: String
    /// The ref to branch from.
    public var ref: String
    /// False when the directory already exists: `-w <name>` reopens it, as it would for the CLI.
    public var create: Bool

    public static let directory = ".claude/worktrees"

    /// - Parameters:
    ///   - name: what the user typed; empty means Clinic names it after the ref.
    ///   - suffix: four characters that keep a generated name unique (injected for tests).
    public static func make(ref: String, name: String, repoRoot: String, suffix: String,
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> WorktreePlan {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = WorkItemBranch.slug(ref, max: 32)
        let resolved = typed.isEmpty ? (slug.isEmpty ? "worktree" : slug) + "-" + suffix : typed
        let path = (repoRoot as NSString).appendingPathComponent(directory + "/" + resolved)
        return WorktreePlan(name: resolved, path: path, branch: "worktree-" + resolved, ref: ref, create: !exists(path))
    }

    /// Four lowercase letters and digits.
    public static func randomSuffix() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }
}

/// Branches a worktree can start from, most recently committed first (ADR-118).
public struct GitBranches: Equatable, Sendable {
    public var local: [String]
    /// Remote-tracking branches with no local branch of the same name, as `origin/name`.
    public var remote: [String]

    public init(local: [String] = [], remote: [String] = []) { self.local = local; self.remote = remote }

    /// Parses `git for-each-ref --format=%(refname) refs/heads refs/remotes`.
    static func parse(_ output: String) -> GitBranches {
        var local: [String] = [], remote: [String] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("refs/heads/") {
                local.append(String(line.dropFirst(11)))
            } else if line.hasPrefix("refs/remotes/") {
                let name = String(line.dropFirst(13))
                // `origin/HEAD` is a pointer to another branch, not a branch.
                if !name.hasSuffix("/HEAD") { remote.append(name) }
            }
        }
        let locals = Set(local)
        remote.removeAll { name in
            guard let slash = name.firstIndex(of: "/") else { return false }
            return locals.contains(String(name[name.index(after: slash)...]))
        }
        return GitBranches(local: local, remote: remote)
    }
}

extension GitRepository {
    /// Local and remote-tracking branches, most recently committed first.
    public func branches() async -> GitBranches {
        let r = await GitProcess.run(["for-each-ref", "--sort=-committerdate", "--format=%(refname)", "refs/heads", "refs/remotes"], in: root)
        return r.status == 0 ? GitBranches.parse(r.stdoutString) : GitBranches()
    }

    /// Carries out a plan: `git worktree add --no-track -b <branch> <path> <ref>`, then the
    /// `.worktreeinclude` copy the CLI would have made. `--no-track` because a branch started from
    /// `origin/develop` would otherwise track it, and a later push would aim at someone else's branch.
    public func createWorktree(_ plan: WorktreePlan) async throws {
        guard plan.create else { return }
        try await run(["worktree", "add", "--no-track", "-b", plan.branch, plan.path, plan.ref])
        await copyWorktreeIncludes(to: plan.path)
    }

    /// Copies the gitignored files `.worktreeinclude` names into a worktree, as the CLI does for the
    /// worktrees it creates but not for one it adopts. Only files that match a pattern *and* are
    /// ignored count, so tracked files are never duplicated. Returns the paths copied.
    @discardableResult
    public func copyWorktreeIncludes(to worktree: String) async -> [String] {
        let include = (root as NSString).appendingPathComponent(".worktreeinclude")
        guard FileManager.default.fileExists(atPath: include) else { return [] }
        let listed = await GitProcess.run(["ls-files", "--others", "--ignored", "-z", "--exclude-from=\(include)"], in: root)
        let candidates = listed.stdoutString.split(separator: "\0").map(String.init)
        guard listed.status == 0, !candidates.isEmpty else { return [] }
        // `check-ignore` echoes the paths the repository's own ignore rules match; it exits 1 when none do.
        let checked = await GitProcess.run(["check-ignore", "-z", "--stdin"], in: root, stdin: Data(candidates.joined(separator: "\0").utf8))
        let ignored = checked.stdoutString.split(separator: "\0").map(String.init)
        var copied: [String] = []
        let fm = FileManager.default
        for rel in ignored {
            let from = (root as NSString).appendingPathComponent(rel)
            let to = (worktree as NSString).appendingPathComponent(rel)
            guard !fm.fileExists(atPath: to) else { continue }
            try? fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if (try? fm.copyItem(atPath: from, toPath: to)) != nil { copied.append(rel) }
        }
        return copied
    }

    private func run(_ args: [String]) async throws {
        let r = await GitProcess.run(args, in: root)
        guard r.status == 0 else { throw r.error(args) }
    }
}
