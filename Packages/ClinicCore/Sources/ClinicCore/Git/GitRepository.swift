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
        return Self.parseCommits(try await git(args).stdoutString)
    }

    /// Records of `--format=%H%x1f%h%x1f%an%x1f%aI%x1f%s`, one per line.
    static func parseCommits(_ out: String) -> [GitCommit] {
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
    ///
    /// Two of these against one scratch index fight over its `index.lock`, and one fails. Callers go
    /// through `SnapshotStore`, which runs them one at a time (ADR-170); tests call this directly.
    public func writeSnapshotTree(_ scratch: GitObjectScratch) async throws -> String {
        try scratch.prepare()
        let env = scratch.environment(repoRoot: root)
        // `add -A .` against an index that may be empty (first call) or warm (every call after).
        let add = await GitProcess.run(["add", "-A", "."], in: root, environment: env)
        if add.status != 0 {
            // A truncated or version-mismatched index is the one failure worth retrying; drop it and rebuild.
            // So is a lock left by a git that was killed mid-write: nothing else writes this index while
            // the store holds it, and a stale lock would otherwise fail every snapshot from then on.
            try? FileManager.default.removeItem(atPath: scratch.indexFile + ".lock")
            try? FileManager.default.removeItem(atPath: scratch.indexFile)
            let retry = await GitProcess.run(["add", "-A", "."], in: root, environment: env)
            guard retry.status == 0 else { throw retry.error(["add", "-A", "."]) }
        }
        await addTrackedButIgnored(env)
        return try await writeTree(env)
    }

    /// `add -A` leaves out a file that matches `.gitignore`, even one the repository tracks — a
    /// force-added file, or one whose ignore rule came later. Its absence from the snapshot read as a
    /// deletion against `HEAD`, and its edits were invisible to every turn (ADR-184). The user's own
    /// index says which files those are; it is only read.
    private func addTrackedButIgnored(_ env: [String: String]) async {
        let listed = await GitProcess.run(["ls-files", "-ci", "--exclude-standard", "-z"], in: root)
        guard listed.status == 0, !listed.stdout.isEmpty else { return }
        // A file gone from disk has nothing to add, and naming it would fail the whole command.
        let present = listed.stdout.split(separator: 0, omittingEmptySubsequences: true).filter {
            FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(String(decoding: $0, as: UTF8.self)))
        }
        guard !present.isEmpty else { return }
        var input = Data()
        for path in present { input.append(contentsOf: path); input.append(0) }
        var literal = env
        literal["GIT_LITERAL_PATHSPECS"] = "1"
        _ = await GitProcess.run(["add", "-f", "--pathspec-from-file=-", "--pathspec-file-nul"], in: root, stdin: input, environment: literal)
    }

    private func writeTree(_ env: [String: String]) async throws -> String {
        let out = try await git(["write-tree"], environment: env).stdoutString
        let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.count >= 40 else {
            throw GitError(command: "write-tree", exitCode: 0, stderr: "", description: "git write-tree produced no tree")
        }
        return sha
    }

    /// The user's index as a tree, **without writing to the repository** (ADR-183): `git write-tree`
    /// against the real index would add tree objects to the user's object store, so it runs against a
    /// copy of the index and writes into `scratch`. The blobs a staged file names are already in the
    /// repository, which the scratch store reads through alternates.
    ///
    /// Throws while the index holds unmerged entries: a conflicted index is not a tree.
    public func indexTree(_ scratch: GitObjectScratch) async throws -> String {
        try scratch.prepare()
        let located = try await git(["rev-parse", "--git-path", "index"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = located.hasPrefix("/") ? located : (root as NSString).appendingPathComponent(located)
        guard FileManager.default.fileExists(atPath: index) else { return try await emptyTree() }
        let copy = scratch.indexFile + ".staged"
        try? FileManager.default.removeItem(atPath: copy)
        try? FileManager.default.removeItem(atPath: copy + ".lock")
        try FileManager.default.copyItem(atPath: index, toPath: copy)
        var env = scratch.environment(repoRoot: root)
        env["GIT_INDEX_FILE"] = copy
        return try await writeTree(env)
    }

    /// `onto`, with every path that differs between `clean` and `dirty` taken from `dirty` (ADR-185).
    ///
    /// This is how uncommitted work is carried across a checkout that moved: `clean` is the commit a
    /// turn started on, `dirty` the snapshot taken there, and `onto` the commit the checkout moved to.
    /// The result is the tree the turn would have started from had the checkout already been there.
    /// Written through a scratch index of its own, so callers still serialise it with the snapshots.
    public func tree(_ onto: String, carrying dirty: String, over clean: String, scratch: GitObjectScratch) async throws -> String {
        guard clean != dirty else { return onto }
        try scratch.prepare()
        var env = scratch.environment(repoRoot: root)
        let index = scratch.indexFile + ".carry"
        env["GIT_INDEX_FILE"] = index
        try? FileManager.default.removeItem(atPath: index)
        try? FileManager.default.removeItem(atPath: index + ".lock")

        // `:<old mode> <new mode> <old sha> <new sha> <status>\0<path>\0`, one pair per changed path.
        let raw = try await git(["diff-tree", "-r", "--raw", "--no-renames", "--no-abbrev", "-z", clean, dirty], environment: env).stdout
        let fields = raw.split(separator: 0, omittingEmptySubsequences: true)
        var input = Data()
        var i = 0
        while i + 1 < fields.count {
            let meta = String(decoding: fields[i], as: UTF8.self).split(separator: " ")
            let path = fields[i + 1]
            i += 2
            guard meta.count >= 5 else { continue }
            // Mode 0 removes the path, which is what a file deleted before the turn began needs.
            let removed = meta[4].hasPrefix("D")
            input.append(contentsOf: "\(removed ? "0" : String(meta[1])) \(meta[3])\t".utf8)
            input.append(contentsOf: path)
            input.append(0)
        }
        _ = try await git(["read-tree", onto], environment: env)
        if !input.isEmpty {
            _ = try await git(["update-index", "--replace", "-z", "--index-info"], stdin: input, environment: env)
        }
        return try await writeTree(env)
    }

    // MARK: Trees and commits (ADR-183, ADR-185)

    /// The commit `HEAD` names and the branch it is on; both nil in a repository with no commits, and
    /// the branch nil when detached.
    public func headState() async -> (commit: String?, branch: String?) {
        let r = await GitProcess.run(["rev-parse", "--verify", "-q", "HEAD"], in: root)
        let commit = r.status == 0 ? r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (commit.isEmpty ? nil : commit, await currentBranch())
    }

    /// The tree of nothing, which is what a root commit and an unborn branch diff against.
    public func emptyTree() async throws -> String {
        let out = try await git(["hash-object", "-t", "tree", "/dev/null"]).stdoutString
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The tree of a commit's first parent, or the empty tree for a root commit — the base `git show
    /// -m --first-parent` diffs a commit against.
    public func parentTree(of sha: String) async throws -> String {
        let r = await GitProcess.run(["rev-parse", "--verify", "-q", "\(sha)^^{tree}"], in: root)
        let tree = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !tree.isEmpty ? tree : try await emptyTree()
    }

    public func mergeBase(_ a: String, _ b: String) async -> String? {
        let r = await GitProcess.run(["merge-base", a, b], in: root)
        let sha = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !sha.isEmpty ? sha : nil
    }

    public func isAncestor(_ ancestor: String, of descendant: String) async -> Bool {
        await GitProcess.run(["merge-base", "--is-ancestor", ancestor, descendant], in: root).status == 0
    }

    /// The newest commit on `head`'s first-parent line that was committed before `date`: the history
    /// that was already there, as opposed to what has been committed since (ADR-185).
    public func newestCommit(reachableFrom head: String, before date: Date) async -> String? {
        let r = await GitProcess.run(["rev-list", "-1", "--first-parent", "--before=@\(Int(date.timeIntervalSince1970))", head], in: root)
        let sha = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !sha.isEmpty ? sha : nil
    }

    /// A file as it stands in a tree, when it is text of a size worth highlighting whole (ADR-186).
    public func text(of path: String, in tree: String, scratch: GitObjectScratch?, limit: Int = 1_000_000) async -> String? {
        guard let data = await data(of: path, in: tree, scratch: scratch, limit: limit), !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A file's bytes as they stand in a tree, whatever they are — an image, for one (ADR-189). nil
    /// when the tree has no such file or it is larger than `limit`.
    public func data(of path: String, in tree: String, scratch: GitObjectScratch?, limit: Int = 64_000_000) async -> Data? {
        try? scratch?.prepare()
        let env = scratch?.environment(repoRoot: root) ?? [:]
        let object = "\(tree):\(path)"
        let size = await GitProcess.run(["cat-file", "-s", object], in: root, environment: env)
        guard size.status == 0, let bytes = Int(size.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)), bytes <= limit else { return nil }
        let blob = await GitProcess.run(["cat-file", "blob", object], in: root, environment: env)
        guard blob.status == 0 else { return nil }
        return blob.stdout
    }

    /// `--numstat` totals for a tree pair. Cheap next to a patch, which is what makes per-turn
    /// `+n −n` in the turn menu affordable.
    public func stat(from base: String, to head: String, scratch: GitObjectScratch?) async throws -> DiffStat {
        guard base != head else { return DiffStat() }
        try scratch?.prepare()
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
    ///
    /// `context` widens the lines of context around each change, and `paths` narrows the diff to
    /// those files, which is how one file is re-read whole (ADR-188). A renamed file needs both of
    /// its names in `paths`, or it reads as an addition.
    public func diff(from base: String, to head: String, scratch: GitObjectScratch?,
                     context: Int? = nil, paths: [String] = []) async throws -> UnifiedDiff {
        guard base != head else { return UnifiedDiff() }
        // Git refuses a `GIT_OBJECT_DIRECTORY` that does not exist, and two commits can be compared
        // before any snapshot has made it.
        try scratch?.prepare()
        var env = scratch?.environment(repoRoot: root) ?? [:]
        var args = ["diff-tree", "-p", "-r", "--find-renames"] + Self.diffFlags
        if let context { args.append("-U\(context)") }
        args += [base, head]
        if !paths.isEmpty {
            env["GIT_LITERAL_PATHSPECS"] = "1"
            args += ["--"] + paths
        }
        return UnifiedDiff.parse(try await git(args, environment: env).stdoutString)
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

    /// What every git subprocess runs under: the tool `PATH` (ADR-086), the C locale so stderr can be
    /// classified, and no terminal prompt, which would hang a process that has no terminal.
    static func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessEnvironment.withToolPaths()
        env["LANG"] = "C"
        env["LC_ALL"] = "C"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        for (k, v) in extra { env[k] = v }
        return env
    }

    private static func runSync(_ args: [String], in directory: String, stdin: Data?, environment: [String: String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // `core.quotepath=off`: paths arrive as UTF-8 rather than as octal escapes (ADR-184). The parser
        // decodes the escapes too, for a diff that did not come from here.
        p.arguments = ["git", "-c", "core.quotepath=off", "-C", directory] + args
        p.environment = Self.environment(adding: environment)

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
