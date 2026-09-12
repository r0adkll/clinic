import Foundation

/// Read/write git operations for one repository. Every method shells out to `git -C <root>` off the
/// main actor; stdout and stderr are captured separately and a non-zero exit throws `GitError`.
public actor GitRepository {
    /// Absolute top-level path of the working tree. `nonisolated` because it never changes: callers
    /// need it to key caches and scratch directories without hopping onto the actor.
    public nonisolated let root: String

    public init(root: String) { self.root = root }

    /// `git rev-parse --show-toplevel` from a directory; nil when not a repo.
    public static func discover(from directory: String) async -> GitRepository? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        let r = await GitProcess.run(["rev-parse", "--show-toplevel"], in: directory)
        guard r.status == 0 else { return nil }
        let top = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? nil : GitRepository(root: top)
    }

    /// `git rev-parse --git-common-dir`, absolute; nil when not a repo.
    ///
    /// The *common* directory, not `--git-dir`: in a linked worktree (ADR-083) `.git` is a file and
    /// the per-worktree directory holds only that checkout's HEAD and index, while `refs/remotes`
    /// — what a push moves, and what ADR-127 watches — lives in the main repository's `.git`.
    /// Git answers relatively (`.git`) when asked from the top level, so the result is resolved
    /// against the directory it was asked from.
    public static func commonDirectory(from directory: String) async -> String? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        let r = await GitProcess.run(["rev-parse", "--git-common-dir"], in: directory)
        guard r.status == 0 else { return nil }
        let out = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }
        let url = out.hasPrefix("/") ? URL(filePath: out) : URL(filePath: directory).appending(path: out)
        return url.standardizedFileURL.path
    }

    // MARK: Status

    /// `git status --porcelain=v2 --branch -z`.
    public func status() async throws -> GitStatusSnapshot {
        let out = try await git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]).stdout
        return Self.parseStatus(out)
    }

    static func parseStatus(_ data: Data) -> GitStatusSnapshot {
        var snap = GitStatusSnapshot()
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            i += 1
            if t.hasPrefix("# ") {
                let parts = t.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.head":
                    if parts[1] == "(detached)" { snap.isDetached = true; snap.branch = nil } else { snap.branch = parts[1] }
                case "branch.upstream": snap.upstream = parts[1]
                case "branch.ab":
                    for ab in parts[1].split(separator: " ") {
                        if ab.hasPrefix("+") { snap.ahead = Int(ab.dropFirst()) ?? 0 }
                        if ab.hasPrefix("-") { snap.behind = Int(ab.dropFirst()) ?? 0 }
                    }
                default: break
                }
                continue
            }
            guard let kind = t.first else { continue }
            switch kind {
            case "1":
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                let f = t.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
                guard f.count == 9 else { continue }
                let (x, y) = Self.xy(f[1])
                snap.files.append(GitFileStatus(path: f[8], index: x, worktree: y))
            case "2":
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\0<origPath>
                let f = t.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
                guard f.count == 10 else { continue }
                let orig = i < tokens.count ? tokens[i] : nil
                i += 1
                let (x, y) = Self.xy(f[1])
                snap.files.append(GitFileStatus(path: f[9], oldPath: orig, index: x, worktree: y))
            case "u":
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                let f = t.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
                guard f.count == 11 else { continue }
                let (x, y) = Self.xy(f[1])
                snap.files.append(GitFileStatus(path: f[10], index: x ?? .unmerged, worktree: y ?? .unmerged, isConflicted: true))
            case "?":
                snap.files.append(GitFileStatus(path: String(t.dropFirst(2)), worktree: .untracked))
            default:
                // "!" ignored entries are not requested; anything else is skipped.
                continue
            }
        }
        return snap
    }

    private static func xy(_ s: String) -> (GitChangeKind?, GitChangeKind?) {
        let chars = Array(s)
        guard chars.count == 2 else { return (nil, nil) }
        return (GitChangeKind(porcelainLetter: chars[0]), GitChangeKind(porcelainLetter: chars[1]))
    }

    // MARK: Diffs

    private static let diffFlags = ["--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/"]

    /// `git diff [--cached] -- path`; untracked files are diffed against `/dev/null` with `--no-index`.
    public func diff(path: String, staged: Bool) async throws -> UnifiedDiff {
        if !staged, await !isTracked(path) {
            return UnifiedDiff.parse(try await untrackedDiff(path))
        }
        var args = ["diff"] + Self.diffFlags
        if staged { args.append("--cached") }
        args += ["--", path]
        return UnifiedDiff.parse(try await git(args).stdoutString)
    }

    /// `git diff [--cached]` for the whole tree. The unstaged variant also appends a `/dev/null` diff for every untracked file.
    public func diffAll(staged: Bool) async throws -> UnifiedDiff {
        var args = ["diff"] + Self.diffFlags
        if staged { args.append("--cached") }
        var text = try await git(args).stdoutString
        if !staged {
            let untracked = try await git(["ls-files", "--others", "--exclude-standard", "-z"]).stdout
            for p in untracked.split(separator: 0, omittingEmptySubsequences: true) {
                let path = String(decoding: p, as: UTF8.self)
                if let d = try? await untrackedDiff(path) {
                    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                    text += d
                }
            }
        }
        return UnifiedDiff.parse(text)
    }

    /// `git diff --no-index -- /dev/null path`; exit code 1 means "differences found" and is success here.
    private func untrackedDiff(_ path: String) async throws -> String {
        let args = ["diff", "--no-index"] + Self.diffFlags + ["--", "/dev/null", path]
        let r = await GitProcess.run(args, in: root)
        guard r.status == 0 || r.status == 1 else { throw r.error(args) }
        return r.stdoutString
    }

    private func isTracked(_ path: String) async -> Bool {
        await GitProcess.run(["ls-files", "--error-unmatch", "--", path], in: root).status == 0
    }

    // MARK: Index and worktree mutations

    /// `git add -A -- paths`.
    public func stage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await git(["add", "-A", "--"] + paths)
    }

    /// `git reset -q -- paths`.
    public func unstage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await git(["reset", "-q", "--"] + paths)
    }

    /// Tracked files: unstage, then `git checkout -- path`. Untracked files (including files that were only
    /// staged as new) are removed from disk.
    public func discard(path: String) async throws {
        let abs = (root as NSString).appendingPathComponent(path)
        if await isTracked(path) {
            _ = try await git(["reset", "-q", "--", path])
            if await isTracked(path) {
                _ = try await git(["checkout", "--", path])
                return
            }
        }
        if FileManager.default.fileExists(atPath: abs) {
            try FileManager.default.removeItem(atPath: abs)
        }
    }

    /// `git apply [--cached] [--reverse] --whitespace=nowarn -` with the patch on stdin.
    public func apply(patch: String, staged: Bool, reverse: Bool) async throws {
        var args = ["apply", "--whitespace=nowarn"]
        if staged { args.append("--cached") }
        if reverse { args.append("--reverse") }
        args.append("-")
        _ = try await git(args, stdin: Data(patch.utf8))
    }

    // MARK: Branches and history

    /// `origin/HEAD` symbolic ref → "main"; else "main"/"master" if they exist locally; else nil.
    public func defaultBranch() async -> String? {
        let r = await GitProcess.run(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], in: root)
        if r.status == 0 {
            let ref = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = ref.firstIndex(of: "/") { return String(ref[ref.index(after: slash)...]) }
            if !ref.isEmpty { return ref }
        }
        for name in ["main", "master"] where await refExists("refs/heads/\(name)") { return name }
        return nil
    }

    /// Commits on the current branch relative to the default branch (`base..HEAD`) when one exists and differs from
    /// the current branch; otherwise the last `limit` commits. Empty when the repository has no commits.
    public func commits(limit: Int = 100) async throws -> [GitCommit] {
        guard await refExists("HEAD") else { return [] }
        var args = ["log", "--no-color", "--format=%H%x1f%h%x1f%an%x1f%aI%x1f%s", "-n", String(max(limit, 1))]
        if let base = await branchBaseRef() { args.append("\(base)..HEAD") }
        let out = try await git(args).stdoutString
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return out.split(separator: "\n").compactMap { record in
            let f = record.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { return nil }
            return GitCommit(sha: f[0], shortSha: f[1], author: f[2], date: iso.date(from: f[3]) ?? Date(timeIntervalSince1970: 0), subject: f[4])
        }
    }

    /// `git commit -q -m message [--amend]`. An empty message with `amend` keeps the previous message.
    public func commit(message: String, amend: Bool = false) async throws {
        var args = ["commit", "-q"]
        if amend { args.append("--amend") }
        if message.isEmpty && amend { args.append("--no-edit") } else { args += ["-m", message] }
        _ = try await git(args)
    }

    /// Short branch name; nil when detached or not a repository.
    // MARK: Upkeep (ADR-065)

    /// `git pull --ff-only`; returns git's output.
    public func pull() async throws -> String {
        let r = try await git(["pull", "--ff-only"])
        return r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func checkout(_ branch: String) async throws {
        _ = try await git(["checkout", branch])
    }

    public struct Worktree: Sendable, Hashable {
        public var path: String
        public var head: String?
        public var branch: String?     // refs/heads/… stripped
        public var isMain: Bool
    }

    /// `git worktree list --porcelain`.
    public func worktrees() async throws -> [Worktree] {
        let r = try await git(["worktree", "list", "--porcelain"])
        var out: [Worktree] = []
        var current: Worktree?
        for line in r.stdoutString.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let c = current { out.append(c) }
                current = Worktree(path: String(line.dropFirst(9)), head: nil, branch: nil, isMain: out.isEmpty)
            } else if line.hasPrefix("HEAD ") { current?.head = String(line.dropFirst(5)) }
            else if line.hasPrefix("branch ") { current?.branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
        }
        if let c = current { out.append(c) }
        return out
    }

    /// Unregisters a worktree whose directory may already be gone (`--force`).
    public func removeWorktree(_ path: String) async throws {
        _ = try await git(["worktree", "remove", "--force", path])
    }

    /// Re-registers a worktree for an existing branch at `path` (used by Undo).
    public func addWorktree(path: String, branch: String) async throws {
        _ = try await git(["worktree", "add", path, branch])
    }

    /// Prunes stale worktree entries (after a directory was moved away).
    public func pruneWorktrees() async throws {
        _ = try await git(["worktree", "prune"])
    }

    public func currentBranch() async -> String? {
        let r = await GitProcess.run(["symbolic-ref", "--short", "-q", "HEAD"], in: root)
        guard r.status == 0 else { return nil }
        let b = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? nil : b
    }

    private func refExists(_ ref: String) async -> Bool {
        await GitProcess.run(["rev-parse", "--verify", "-q", ref], in: root).status == 0
    }


    /// The ref the current branch should be compared against — the default branch, local or on
    /// `origin` — or nil when there is none, or when it *is* the current branch.
    public func branchBaseRef() async -> String? {
        guard let base = await defaultBranch(), base != (await currentBranch()) else { return nil }
        if await refExists("refs/heads/\(base)") { return base }
        if await refExists("refs/remotes/origin/\(base)") { return "origin/\(base)" }
        return nil
    }

    /// `git diff <base>...<head>`: everything the branch added since it diverged, which is what the
    /// branch scope shows and what a reviewer of the branch would see.
    public func diff(branchFrom base: String, to head: String = "HEAD") async throws -> UnifiedDiff {
        let args = ["diff"] + Self.diffFlags + ["\(base)...\(head)"]
        return UnifiedDiff.parse(try await git(args).stdoutString)
    }

    /// One commit against its first parent. `-m --first-parent` is what makes a merge commit show a
    /// diff at all; without it `git show` prints a header and nothing else.
    public func diff(commit sha: String) async throws -> UnifiedDiff {
        let args = ["show", "--format=", "-m", "--first-parent"] + Self.diffFlags + [sha]
        return UnifiedDiff.parse(try await git(args).stdoutString)
    }

    // MARK: Snapshots (ADR-080)

    /// Writes a tree object recording the whole working tree — tracked, modified and untracked
    /// alike, `.gitignore` honoured — **without touching the repository**. New objects land in
    /// `scratch.objectDirectory`; the repo's own object store is reached read-only through
    /// alternates, and the index git needs is `scratch.indexFile`, never the user's.
    ///
    /// The scratch index is kept between calls on purpose: it carries git's stat cache, which is
    /// what makes a repeat snapshot a stat walk rather than a re-hash of every file.
    public func writeSnapshotTree(_ scratch: GitObjectScratch) async throws -> String {
        try scratch.prepare()
        let env = scratch.environment(repoRoot: root)
        // `add -A .` against an index that may be empty (first call) or warm (every call after).
        let add = await GitProcess.run(["add", "-A", "."], in: root, environment: env)
        if add.status != 0 {
            // A truncated or version-mismatched index is the one failure worth retrying; drop it and rebuild.
            try? FileManager.default.removeItem(atPath: scratch.indexFile)
            let retry = await GitProcess.run(["add", "-A", "."], in: root, environment: env)
            guard retry.status == 0 else { throw retry.error(["add", "-A", "."]) }
        }
        let out = try await git(["write-tree"], environment: env).stdoutString
        let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.count >= 40 else {
            throw GitError(command: "write-tree", exitCode: 0, stderr: "", description: "git write-tree produced no tree")
        }
        return sha
    }

    /// `--numstat` totals for a tree pair. Cheap next to a patch, which is what makes per-turn
    /// `+n −n` in the turn menu affordable.
    public func stat(from base: String, to head: String, scratch: GitObjectScratch?) async throws -> DiffStat {
        guard base != head else { return DiffStat() }
        let env = scratch?.environment(repoRoot: root) ?? [:]
        let out = try await git(["diff-tree", "-r", "--numstat", "--no-color", base, head], environment: env).stdoutString
        return DiffStat(numstat: out)
    }

    /// `HEAD^{tree}`-style resolution, so a commit or branch can be one side of a snapshot diff.
    public func tree(of ref: String) async throws -> String {
        let out = try await git(["rev-parse", "--verify", "-q", "\(ref)^{tree}"]).stdoutString
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unified diff between two trees. `scratch` must be the store the trees were written into,
    /// otherwise git cannot resolve them.
    public func diff(from base: String, to head: String, scratch: GitObjectScratch?) async throws -> UnifiedDiff {
        guard base != head else { return UnifiedDiff() }
        let env = scratch?.environment(repoRoot: root) ?? [:]
        let args = ["diff-tree", "-p", "-r", "--find-renames"] + Self.diffFlags + [base, head]
        return UnifiedDiff.parse(try await git(args, environment: env).stdoutString)
    }

    /// Diff from a snapshot tree to the working tree as it is right now, by taking a fresh snapshot
    /// and comparing the pair. Used for the in-flight turn and every worktree-headed scope.
    public func diff(from base: String, toWorktree scratch: GitObjectScratch) async throws -> UnifiedDiff {
        let head = try await writeSnapshotTree(scratch)
        return try await diff(from: base, to: head, scratch: scratch)
    }

    // MARK: Process plumbing

    @discardableResult
    private func git(_ args: [String], stdin: Data? = nil, environment: [String: String] = [:]) async throws -> GitProcess.Result {
        let r = await GitProcess.run(args, in: root, stdin: stdin, environment: environment)
        guard r.status == 0 else { throw r.error(args) }
        return r
    }
}

/// Runs `/usr/bin/env git -C <dir> …` on a global queue with a stable C locale and no optional locks.
enum GitProcess {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: String
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        func error(_ args: [String]) -> GitError { GitError(command: args.joined(separator: " "), exitCode: status, stderr: stderr) }
    }

    static func run(_ args: [String], in directory: String, stdin: Data? = nil, environment: [String: String] = [:]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(args, in: directory, stdin: stdin, environment: environment))
            }
        }
    }

    private static func runSync(_ args: [String], in directory: String, stdin: Data?, environment: [String: String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", directory] + args
        var env = ProcessEnvironment.withToolPaths()
        env["LANG"] = "C"
        env["LC_ALL"] = "C"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        for (k, v) in environment { env[k] = v }
        p.environment = env

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let input = stdin.map { _ in Pipe() }
        p.standardInput = input ?? FileHandle.nullDevice

        do { try p.run() } catch {
            return Result(status: -1, stdout: Data(), stderr: "could not launch git: \(error.localizedDescription)")
        }

        // Drain both pipes concurrently so a chatty stderr cannot deadlock stdout (and vice versa).
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if let input, let stdin {
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        }
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
    }
}
