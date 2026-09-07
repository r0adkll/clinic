import Foundation
import Testing
@testable import ClinicCore

// MARK: - Parser

@Suite struct UnifiedDiffTests {
    static let fixture = """
    diff --git a/src/main.swift b/src/main.swift
    index 1111111..2222222 100644
    --- a/src/main.swift
    +++ b/src/main.swift
    @@ -1,4 +1,5 @@
     import Foundation
    -let a = 1
    +let a = 2
    +let b = 3
     print(a)
     // end
    @@ -20,3 +21,3 @@ func heading() {
     x
    -y
    +z
     w
    \\ No newline at end of file
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,2 @@
    +hello
    +world
    diff --git a/img.png b/img.png
    index 4444444..5555555 100644
    Binary files a/img.png and b/img.png differ
    diff --git a/old.txt b/renamed.txt
    similarity index 90%
    rename from old.txt
    rename to renamed.txt
    index 6666666..7777777 100644
    --- a/old.txt
    +++ b/renamed.txt
    @@ -1,2 +1,2 @@
     keep
    -gone
    +here

    """

    @Test func parsesFilesHunksAndLines() {
        let diff = UnifiedDiff.parse(Self.fixture)
        #expect(diff.files.count == 4)

        let main = diff.files[0]
        #expect(main.path == "src/main.swift")
        #expect(main.oldPath == "src/main.swift" && main.newPath == "src/main.swift")
        #expect(!main.isNew && !main.isDeleted && !main.isBinary)
        #expect(main.headerLines == ["diff --git a/src/main.swift b/src/main.swift", "index 1111111..2222222 100644", "--- a/src/main.swift", "+++ b/src/main.swift"])
        #expect(main.hunks.count == 2)
        #expect(main.additions == 3 && main.deletions == 2)

        let h0 = main.hunks[0]
        #expect(h0.id == "1-1-0")
        #expect(h0.oldStart == 1 && h0.oldCount == 4 && h0.newStart == 1 && h0.newCount == 5)
        #expect(h0.heading == nil)
        #expect(h0.headerText == "@@ -1,4 +1,5 @@")
        #expect(h0.lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context, .context])
        #expect(h0.lines.map(\.text) == ["import Foundation", "let a = 1", "let a = 2", "let b = 3", "print(a)", "// end"])
        #expect(h0.lines.map(\.oldLineNumber) == [1, 2, nil, nil, 3, 4])
        #expect(h0.lines.map(\.newLineNumber) == [1, nil, 2, 3, 4, 5])
        #expect(h0.lines.map(\.id) == [0, 1, 2, 3, 4, 5])

        let h1 = main.hunks[1]
        #expect(h1.id == "20-21-1")
        #expect(h1.heading == "func heading() {")
        #expect(h1.headerText == "@@ -20,3 +21,3 @@ func heading() {")
        #expect(h1.lines.map(\.kind) == [.context, .deletion, .addition, .context, .noNewline])
        #expect(h1.lines.last?.text == "No newline at end of file")
        #expect(h1.lines[3].oldLineNumber == 22 && h1.lines[3].newLineNumber == 23)

        let new = diff.files[1]
        #expect(new.isNew && new.oldPath == nil && new.newPath == "new.txt" && new.path == "new.txt")
        #expect(new.hunks.count == 1 && new.additions == 2 && new.deletions == 0)
        #expect(new.hunks[0].oldStart == 0 && new.hunks[0].oldCount == 0 && new.hunks[0].newCount == 2)

        let bin = diff.files[2]
        #expect(bin.isBinary && bin.hunks.isEmpty && bin.path == "img.png")
        #expect(bin.headerLines.last == "Binary files a/img.png and b/img.png differ")

        let ren = diff.files[3]
        #expect(ren.oldPath == "old.txt" && ren.newPath == "renamed.txt" && ren.path == "renamed.txt")
        #expect(ren.hunks.count == 1 && ren.additions == 1 && ren.deletions == 1)
    }

    @Test func hunkPatchRoundTrips() {
        let diff = UnifiedDiff.parse(Self.fixture)
        for file in diff.files where !file.hunks.isEmpty {
            for hunk in file.hunks {
                let again = UnifiedDiff.parse(file.patchText(for: hunk))
                #expect(again.files.count == 1)
                #expect(again.files[0].headerLines == file.headerLines)
                #expect(again.files[0].hunks.count == 1)
                guard var re = again.files[0].hunks.first else { continue }
                re.id = hunk.id   // the id carries the hunk's index within its file, which a single-hunk patch resets to 0
                #expect(re == hunk)
            }
        }
    }

    @Test func lineSelectionPatch() {
        let file = UnifiedDiff.parse(Self.fixture).files[0]
        let hunk = file.hunks[0]
        // Select only "+let b = 3" (id 3): the deletion becomes context, "+let a = 2" is dropped.
        let patch = file.patchText(for: hunk, selectedLineIds: [3])
        let re = UnifiedDiff.parse(patch).files[0].hunks[0]
        #expect(re.oldCount == 4 && re.newCount == 5)
        #expect(re.lines.map(\.kind) == [.context, .context, .addition, .context, .context])
        #expect(re.lines.map(\.text) == ["import Foundation", "let a = 1", "let b = 3", "print(a)", "// end"])

        // Selecting only the deletion drops both additions.
        let del = UnifiedDiff.parse(file.patchText(for: hunk, selectedLineIds: [1])).files[0].hunks[0]
        #expect(del.oldCount == 4 && del.newCount == 3)
        #expect(del.lines.map(\.kind) == [.context, .deletion, .context, .context])

        // A no-newline marker follows its (kept) line and is dropped with an unselected addition.
        let h1 = file.hunks[1]
        let keepContext = UnifiedDiff.parse(file.patchText(for: h1, selectedLineIds: [2])).files[0].hunks[0]
        #expect(keepContext.lines.map(\.kind) == [.context, .context, .addition, .context, .noNewline])
    }

    @Test func toleratesDeletedFileAndModeChange() {
        let text = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 1234567..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/script.sh b/script.sh
        old mode 100644
        new mode 100755

        """
        let diff = UnifiedDiff.parse(text)
        #expect(diff.files.count == 2)
        #expect(diff.files[0].isDeleted && diff.files[0].newPath == nil && diff.files[0].path == "gone.txt")
        #expect(diff.files[0].hunks[0].oldCount == 1 && diff.files[0].hunks[0].newCount == 0 && diff.files[0].deletions == 1)
        #expect(diff.files[1].hunks.isEmpty && diff.files[1].headerLines.count == 3 && diff.files[1].path == "script.sh")
    }
}

// MARK: - Repository (real git)

@Suite(.serialized) struct GitRepositoryTests {
    /// Creates a temp repo on `main` with local identity/signing config so `commit` works on any machine.
    static func makeRepo() throws -> (GitRepository, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-gitrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sh(dir, ["init", "-q", "-b", "main"])
        try sh(dir, ["config", "user.name", "Clinic Tests"])
        try sh(dir, ["config", "user.email", "tests@clinic.local"])
        try sh(dir, ["config", "commit.gpgsign", "false"])
        try sh(dir, ["config", "core.hooksPath", "/dev/null"])
        return (GitRepository(root: dir.path), dir)
    }

    static func sh(_ dir: URL, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "-C", dir.path] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
    }

    static func write(_ dir: URL, _ name: String, _ content: String) throws {
        try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    static func lines(_ n: Int, changing: [Int: String] = [:], inserting: [Int: [String]] = [:]) -> String {
        var out: [String] = []
        for i in 1...n {
            out.append(changing[i] ?? "line \(i)")
            if let extra = inserting[i] { out += extra }
        }
        return out.joined(separator: "\n") + "\n"
    }

    @Test func discoverAndBranch() async throws {
        let (repo, dir) = try Self.makeRepo()
        let sub = dir.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let found = await GitRepository.discover(from: sub.path)
        #expect(found != nil)
        let foundRoot = await found?.root
        #expect(foundRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path } == dir.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(await GitRepository.discover(from: "/") == nil)
        #expect(await repo.currentBranch() == "main")
        // A fresh repo with no commits: status has the branch and no files; no commits; default branch absent until main exists.
        let s = try await repo.status()
        #expect(s.branch == "main" && s.files.isEmpty && !s.isDetached)
        #expect(try await repo.commits().isEmpty)
        #expect(await repo.defaultBranch() == nil)
    }

    @Test func stagingWorkflow() async throws {
        let (repo, dir) = try Self.makeRepo()
        try Self.write(dir, "a.txt", Self.lines(30))
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")
        #expect(await repo.defaultBranch() == "main")

        // Two separate edits (far apart => two hunks) plus an untracked file.
        try Self.write(dir, "a.txt", Self.lines(30, changing: [2: "line two", 28: "line twenty-eight"]))
        try Self.write(dir, "new.txt", "brand new\n")

        let status = try await repo.status()
        #expect(status.branch == "main")
        let a = status.files.first { $0.path == "a.txt" }
        let n = status.files.first { $0.path == "new.txt" }
        #expect(a?.worktree == .modified && a?.index == nil && a?.hasUnstagedChanges == true && a?.hasStagedChanges == false)
        #expect(n?.isUntracked == true && n?.index == nil)
        #expect(status.files.count == 2)

        let unstaged = try await repo.diff(path: "a.txt", staged: false)
        #expect(unstaged.files.count == 1)
        let file = try #require(unstaged.files.first)
        #expect(file.hunks.count == 2)
        #expect(file.additions == 2 && file.deletions == 2)

        // Untracked file diffs against /dev/null.
        let newDiff = try await repo.diff(path: "new.txt", staged: false)
        #expect(newDiff.files.count == 1 && newDiff.files[0].isNew && newDiff.files[0].additions == 1)
        #expect(newDiff.files[0].hunks[0].lines[0].text == "brand new")

        // Stage only the first hunk.
        try await repo.apply(patch: file.patchText(for: file.hunks[0]), staged: true, reverse: false)
        let stagedAfter = try await repo.diff(path: "a.txt", staged: true)
        let unstagedAfter = try await repo.diff(path: "a.txt", staged: false)
        #expect(stagedAfter.files.first?.hunks.count == 1)
        #expect(unstagedAfter.files.first?.hunks.count == 1)
        #expect(stagedAfter.files.first?.hunks.first?.lines.contains { $0.kind == .addition && $0.text == "line two" } == true)
        #expect(unstagedAfter.files.first?.hunks.first?.lines.contains { $0.kind == .addition && $0.text == "line twenty-eight" } == true)
        let mid = try await repo.status().files.first { $0.path == "a.txt" }
        #expect(mid?.index == .modified && mid?.worktree == .modified)

        // Unstage returns to two unstaged hunks.
        try await repo.unstage(paths: ["a.txt"])
        #expect(try await repo.diff(path: "a.txt", staged: false).files.first?.hunks.count == 2)
        #expect(try await repo.diff(path: "a.txt", staged: true).files.isEmpty)

        // diffAll(unstaged) includes the untracked file.
        let all = try await repo.diffAll(staged: false)
        #expect(Set(all.files.map(\.path)) == ["a.txt", "new.txt"])

        // Stage everything and commit.
        try await repo.stage(paths: ["a.txt", "new.txt"])
        #expect(try await repo.diffAll(staged: true).files.count == 2)
        try await repo.commit(message: "second commit")
        #expect(try await repo.status().files.isEmpty)
        let commits = try await repo.commits()
        #expect(commits.count == 2)
        #expect(commits.first?.subject == "second commit")
        #expect(commits.first?.author == "Clinic Tests")
        #expect(commits.first?.shortSha.count ?? 0 >= 7)
        #expect(commits.first.map { $0.sha.hasPrefix($0.shortSha) } == true)
        #expect(abs((commits.first?.date.timeIntervalSinceNow) ?? 1e9) < 600)

        // Amend keeps the count and replaces the subject.
        try await repo.commit(message: "second (amended)", amend: true)
        let amended = try await repo.commits(limit: 10)
        #expect(amended.count == 2 && amended.first?.subject == "second (amended)")

        // Discarding an untracked file removes it.
        try Self.write(dir, "junk.txt", "junk\n")
        #expect(try await repo.status().files.map(\.path) == ["junk.txt"])
        try await repo.discard(path: "junk.txt")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("junk.txt").path))
        #expect(try await repo.status().files.isEmpty)

        // Discarding a tracked modification (even if staged) restores HEAD content.
        try Self.write(dir, "a.txt", Self.lines(30, changing: [1: "changed"]))
        try await repo.stage(paths: ["a.txt"])
        try await repo.discard(path: "a.txt")
        #expect(try await repo.status().files.isEmpty)
        #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8).hasPrefix("line 1\n"))
    }

    @Test func lineSelectionStaging() async throws {
        let (repo, dir) = try Self.makeRepo()
        try Self.write(dir, "a.txt", Self.lines(20))
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")

        try Self.write(dir, "a.txt", Self.lines(20, inserting: [10: ["alpha", "beta"]]))
        let file = try #require(try await repo.diff(path: "a.txt", staged: false).files.first)
        let hunk = try #require(file.hunks.first)
        let firstAdded = try #require(hunk.lines.first { $0.kind == .addition })
        #expect(firstAdded.text == "alpha")

        try await repo.apply(patch: file.patchText(for: hunk, selectedLineIds: [firstAdded.id]), staged: true, reverse: false)

        let staged = try #require(try await repo.diff(path: "a.txt", staged: true).files.first)
        #expect(staged.hunks.count == 1 && staged.additions == 1 && staged.deletions == 0)
        #expect(staged.hunks[0].lines.filter { $0.kind == .addition }.map(\.text) == ["alpha"])

        let remaining = try #require(try await repo.diff(path: "a.txt", staged: false).files.first)
        #expect(remaining.additions == 1 && remaining.hunks[0].lines.filter { $0.kind == .addition }.map(\.text) == ["beta"])

        // Reverse-apply the staged line to unstage it again.
        try await repo.apply(patch: staged.patchText(for: staged.hunks[0]), staged: true, reverse: true)
        #expect(try await repo.diff(path: "a.txt", staged: true).files.isEmpty)
        #expect(try await repo.diff(path: "a.txt", staged: false).files.first?.additions == 2)
    }

    @Test func renamesConflictsAndDetachedHead() async throws {
        let (repo, dir) = try Self.makeRepo()
        try Self.write(dir, "old.txt", Self.lines(20))
        try Self.write(dir, "c.txt", "base\n")
        try await repo.stage(paths: ["old.txt", "c.txt"])
        try await repo.commit(message: "initial")

        try Self.sh(dir, ["mv", "old.txt", "renamed.txt"])
        let s = try await repo.status()
        let r = try #require(s.files.first { $0.path == "renamed.txt" })
        #expect(r.index == .renamed && r.oldPath == "old.txt" && r.worktree == nil)
        try await repo.commit(message: "rename")

        // Conflict: two branches editing c.txt.
        try Self.sh(dir, ["checkout", "-q", "-b", "feature"])
        try Self.write(dir, "c.txt", "feature\n")
        try await repo.stage(paths: ["c.txt"])
        try await repo.commit(message: "feature edit")
        #expect(await repo.currentBranch() == "feature")
        let onBranch = try await repo.commits()
        #expect(onBranch.map(\.subject) == ["feature edit"])   // main..HEAD

        try Self.sh(dir, ["checkout", "-q", "main"])
        try Self.write(dir, "c.txt", "main\n")
        try await repo.stage(paths: ["c.txt"])
        try await repo.commit(message: "main edit")
        let mergeP = Process(); mergeP.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        mergeP.arguments = ["git", "-C", dir.path, "merge", "feature"]
        mergeP.standardOutput = FileHandle.nullDevice; mergeP.standardError = FileHandle.nullDevice
        try mergeP.run(); mergeP.waitUntilExit()
        #expect(mergeP.terminationStatus != 0)
        let conflicted = try await repo.status()
        let c = try #require(conflicted.files.first { $0.path == "c.txt" })
        #expect(c.isConflicted && c.index == .unmerged && c.worktree == .unmerged)
        try Self.sh(dir, ["merge", "--abort"])

        // Detached HEAD.
        try Self.sh(dir, ["checkout", "-q", "--detach", "HEAD"])
        let detached = try await repo.status()
        #expect(detached.isDetached && detached.branch == nil)
        #expect(await repo.currentBranch() == nil)
    }

    @Test func errorsCarryStderr() async throws {
        let (repo, _) = try Self.makeRepo()
        do {
            try await repo.apply(patch: "this is not a patch\n", staged: true, reverse: false)
            Issue.record("expected apply to throw")
        } catch let e as GitError {
            #expect(e.exitCode != 0)
            #expect(e.command.hasPrefix("apply"))
            #expect(e.description.contains("apply"))
        }
    }
}

// MARK: - FSEvents

@Suite struct FSEventsWatcherTests {
    @Test func emitsOnFileWrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-fsevents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let watcher = FSEventsWatcher(paths: [dir.path], latency: 0.1)
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try Data("hello\n".utf8).write(to: dir.appendingPathComponent("file.txt"))
        let changes = watcher.changes
        let batch = await withTimeout(seconds: 5) { () -> [String]? in
            for await b in changes { return b }
            return nil
        }
        let paths = try #require(batch ?? nil)
        #expect(!paths.isEmpty)
        #expect(paths.contains { $0.hasSuffix("file.txt") || $0.hasSuffix(dir.lastPathComponent) })
        watcher.stop()
        watcher.stop()   // idempotent
    }

    @Test func ignoresGitObjects() {
        #expect(FSEventsWatcher.isIgnored("/repo/.git/objects/ab/cdef"))
        #expect(FSEventsWatcher.isIgnored("/repo/.git/objects"))
        #expect(!FSEventsWatcher.isIgnored("/repo/.git/index"))
        #expect(!FSEventsWatcher.isIgnored("/repo/src/objects/a.swift"))
    }
}
