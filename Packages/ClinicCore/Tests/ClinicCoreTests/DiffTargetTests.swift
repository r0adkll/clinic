import Foundation
import Testing
@testable import ClinicCore

/// ADR-183: every scope is two trees. ADR-185: a turn knows where the checkout stood.
@Suite(.serialized) struct DiffTargetTests {
    typealias G = GitRepositoryTests

    static func commit(_ repo: GitRepository, _ dir: URL, _ files: [String: String], _ message: String, at date: Date? = nil) async throws {
        for (name, content) in files {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        try G.sh(dir, ["add", "-A"])
        var env: [String: String] = [:]
        if let date {
            let stamp = "@\(Int(date.timeIntervalSince1970)) +0000"
            env = ["GIT_COMMITTER_DATE": stamp, "GIT_AUTHOR_DATE": stamp]
        }
        let r = await GitProcess.run(["commit", "-q", "-m", message], in: dir.path, environment: env)
        #expect(r.status == 0, "commit failed: \(r.stderr)")
    }

    static func paths(_ store: SnapshotStore, _ pair: DiffPair) async throws -> [String] {
        try await store.diff(pair).files.map(\.path).sorted()
    }

    // MARK: Scopes as pairs

    @Test func uncommittedSidesAreThreePairsOverOneIndex() async throws {
        let (repo, dir, store, _) = try SnapshotTests.makeStore()
        try await Self.commit(repo, dir, ["a.txt": "one\n", "b.txt": "one\n"], "initial")
        let before = SnapshotTests.objectCount(dir)

        try G.write(dir, "a.txt", "one\nstaged\n")
        try G.sh(dir, ["add", "a.txt"])
        try G.write(dir, "b.txt", "one\nunstaged\n")
        try G.write(dir, "new.txt", "untracked\n")

        let staged = try #require(try await store.resolve(.uncommitted(.staged), repoRoot: dir.path))
        let unstaged = try #require(try await store.resolve(.uncommitted(.unstaged), repoRoot: dir.path))
        let all = try #require(try await store.resolve(.uncommitted(.all), repoRoot: dir.path))
        #expect(try await Self.paths(store, staged.pair) == ["a.txt"])
        #expect(try await Self.paths(store, unstaged.pair) == ["b.txt", "new.txt"])
        #expect(try await Self.paths(store, all.pair) == ["a.txt", "b.txt", "new.txt"])
        #expect(staged.pair.head == unstaged.pair.base, "one index tree is the seam between them")
        #expect(all.headIsLive && unstaged.headIsLive && !staged.headIsLive)

        // Reading the index as a tree wrote nothing into the repository and staged nothing.
        #expect(SnapshotTests.objectCount(dir) <= before + 1, "only the blob `git add` itself wrote")
        let probe = await GitProcess.run(["cat-file", "-e", staged.pair.head], in: dir.path)
        #expect(probe.status != 0, "the index tree must not exist in the user's repo")
        let status = try await repo.status()
        #expect(status.files.first { $0.path == "b.txt" }?.index == nil)
    }

    @Test func anUnchangedTreeIsAnEmptyPairWithoutADiff() async throws {
        let (repo, dir, store, _) = try SnapshotTests.makeStore()
        try await Self.commit(repo, dir, ["a.txt": "one\n"], "initial")
        let all = try #require(try await store.resolve(.uncommitted(.all), repoRoot: dir.path))
        #expect(all.pair.isEmpty)
        let again = try #require(try await store.resolve(.uncommitted(.all), repoRoot: dir.path))
        #expect(all.pair == again.pair, "the same trees are the same pair, which is what lets a refresh do nothing")
    }

    @Test func aRepositoryWithNoCommitsDiffsAgainstNothing() async throws {
        let (_, dir, store, _) = try SnapshotTests.makeStore()
        try G.write(dir, "a.txt", "one\n")
        let all = try #require(try await store.resolve(.uncommitted(.all), repoRoot: dir.path))
        #expect(try await Self.paths(store, all.pair) == ["a.txt"])
    }

    @Test func branchAndCommitResolveToTheTreesGitWouldCompare() async throws {
        let (repo, dir, store, _) = try SnapshotTests.makeStore()
        try await Self.commit(repo, dir, ["a.txt": "one\n"], "initial")
        try G.sh(dir, ["checkout", "-q", "-b", "feature"])
        try await Self.commit(repo, dir, ["b.txt": "feature\n"], "feature work")
        try G.sh(dir, ["checkout", "-q", "main"])
        try await Self.commit(repo, dir, ["c.txt": "main moved on\n"], "main work")
        try G.sh(dir, ["checkout", "-q", "feature"])

        let branch = try #require(try await store.resolve(.branch(base: "main"), repoRoot: dir.path))
        #expect(try await Self.paths(store, branch.pair) == ["b.txt"], "from the merge base, so main's own commit is not in it")
        let viaGit = try await repo.diff(branchFrom: "main")
        #expect(try await store.diff(branch.pair) == viaGit)

        let head = try #require(await repo.headState().commit)
        let commit = try #require(try await store.resolve(.commit(head), repoRoot: dir.path))
        let shown = try await repo.diff(commit: head)
        #expect(try await store.diff(commit.pair) == shown)
    }

    @Test func aRootCommitDiffsAgainstTheEmptyTree() async throws {
        let (repo, dir, store, _) = try SnapshotTests.makeStore()
        try await Self.commit(repo, dir, ["a.txt": "one\n"], "initial")
        let head = try #require(await repo.headState().commit)
        let commit = try #require(try await store.resolve(.commit(head), repoRoot: dir.path))
        #expect(try await Self.paths(store, commit.pair) == ["a.txt"])
    }

    @Test func aTrackedFileThatIsAlsoIgnoredIsNotReportedDeleted() async throws {
        let (repo, dir, store, _) = try SnapshotTests.makeStore()
        try G.write(dir, ".gitignore", "secret.cfg\n")
        try G.write(dir, "secret.cfg", "v1\n")
        try G.sh(dir, ["add", ".gitignore"])
        try G.sh(dir, ["add", "-f", "secret.cfg"])
        try await repo.commit(message: "initial")

        let clean = try #require(try await store.resolve(.uncommitted(.all), repoRoot: dir.path))
        #expect(clean.pair.isEmpty, "a clean checkout must read as clean")

        try G.write(dir, "secret.cfg", "v2\n")
        let edited = try #require(try await store.resolve(.uncommitted(.all), repoRoot: dir.path))
        let diff = try await store.diff(edited.pair)
        #expect(diff.files.map(\.path) == ["secret.cfg"] && diff.files[0].isDeleted == false)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("secret.cfg"))
        let removed = try #require(try await store.resolve(.uncommitted(.all), repoRoot: dir.path))
        #expect(try await store.diff(removed.pair).files.first?.isDeleted == true)
    }

    @Test func oneFileCanBeReadWhole() async throws {
        let (repo, dir, store, _) = try SnapshotTests.makeStore()
        try await Self.commit(repo, dir, ["a.txt": G.lines(40)], "initial")
        try G.write(dir, "a.txt", G.lines(40, changing: [20: "changed"]))
        let all = try #require(try await store.resolve(.uncommitted(.all), repoRoot: dir.path))
        let brief = try #require(try await store.diff(all.pair).files.first)
        #expect(brief.hunks[0].lines.count == 8)
        let whole = try #require(try await store.file(brief, of: all.pair, context: 100_000))
        #expect(whole.hunks.count == 1 && whole.hunks[0].lines.count == 41)
        #expect(await store.text(of: "a.txt", in: all.pair.head, repoRoot: dir.path) == G.lines(40, changing: [20: "changed"]))
        #expect(await store.text(of: "a.txt", in: all.pair.base, repoRoot: dir.path) == G.lines(40))
    }

    // MARK: A checkout that moves (ADR-185)

    /// `main` with one commit and a `feature` branch three files ahead, all committed an hour ago.
    static func twoBranches() async throws -> (GitRepository, URL, SnapshotStore) {
        let (repo, dir, store, _) = try SnapshotTests.makeStore()
        let past = Date().addingTimeInterval(-3600)
        try await commit(repo, dir, ["a.txt": "one\n"], "initial", at: past)
        try G.sh(dir, ["checkout", "-q", "-b", "feature"])
        try await commit(repo, dir, ["f1.txt": "1\n", "f2.txt": "2\n", "f3.txt": "3\n"], "feature work", at: past)
        try G.sh(dir, ["checkout", "-q", "main"])
        return (repo, dir, store)
    }

    @Test func aBranchSwitchIsTakenOutOfTheTurn() async throws {
        let (_, dir, store) = try await Self.twoBranches()
        let session = SessionID("s1")
        _ = await store.beginTurn(session, repoRoot: dir.path, prompt: "switch and fix")
        try G.sh(dir, ["checkout", "-q", "feature"])
        try G.write(dir, "f2.txt", "2\nfixed\n")

        // While it runs.
        let open = try #require(await store.snapshots(session: session, repoRoot: dir.path).openTurn)
        let live = try #require(try await store.resolve(.turn(open), repoRoot: dir.path))
        #expect(try await Self.paths(store, live.pair) == ["f2.txt"])
        #expect(live.move?.fromBranch == "main" && live.move?.toBranch == "feature")

        // And once it has stopped.
        let closed = try #require(await store.endTurn(session, repoRoot: dir.path))
        #expect(closed.baseBranch == "main" && closed.headBranch == "feature" && closed.baseCommit != closed.headCommit)
        let resolved = try #require(try await store.resolve(.turn(closed), repoRoot: dir.path))
        #expect(try await Self.paths(store, resolved.pair) == ["f2.txt"], "only what the turn wrote")
        let whole = try #require(resolved.whole)
        #expect(try await Self.paths(store, whole) == ["f1.txt", "f2.txt", "f3.txt"], "the whole pair still holds the switch")
        let file = try #require(try await store.diff(resolved.pair).files.first)
        #expect(file.additions == 1 && file.deletions == 0 && !file.isNew, "diffed from the branch's own version, not as a new file")
    }

    @Test func aSwitchThatChangedNothingIsAnEmptyTurn() async throws {
        let (_, dir, store) = try await Self.twoBranches()
        _ = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "switch back")
        try G.sh(dir, ["checkout", "-q", "feature"])
        let closed = try #require(await store.endTurn(SessionID("s1"), repoRoot: dir.path))
        #expect(!closed.isEmpty, "the trees differ by three files")
        let resolved = try #require(try await store.resolve(.turn(closed), repoRoot: dir.path))
        #expect(resolved.pair.isEmpty && resolved.move != nil)
    }

    @Test func switchingBackToAnAncestorIsAlsoAMove() async throws {
        let (_, dir, store) = try await Self.twoBranches()
        try G.sh(dir, ["checkout", "-q", "feature"])
        _ = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "back to main")
        try G.sh(dir, ["checkout", "-q", "main"])
        try G.write(dir, "a.txt", "one\ntwo\n")
        let closed = try #require(await store.endTurn(SessionID("s1"), repoRoot: dir.path))
        let resolved = try #require(try await store.resolve(.turn(closed), repoRoot: dir.path))
        #expect(try await Self.paths(store, resolved.pair) == ["a.txt"])
    }

    @Test func uncommittedWorkAtTheStartIsCarriedAcrossTheMove() async throws {
        let (_, dir, store) = try await Self.twoBranches()
        try G.write(dir, "notes.txt", "mine, from before the turn\n")
        _ = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "switch")
        try G.sh(dir, ["checkout", "-q", "feature"])
        try G.write(dir, "f1.txt", "1\nedited\n")
        let closed = try #require(await store.endTurn(SessionID("s1"), repoRoot: dir.path))
        let resolved = try #require(try await store.resolve(.turn(closed), repoRoot: dir.path))
        #expect(try await Self.paths(store, resolved.pair) == ["f1.txt"], "a file that was already there is not the turn's")
    }

    @Test func aTurnThatCommitsItsOwnWorkHasNotMoved() async throws {
        let (repo, dir, store) = try await Self.twoBranches()
        _ = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "write and commit", at: Date().addingTimeInterval(-60))
        try await Self.commit(repo, dir, ["a.txt": "one\ntwo\n"], "the turn's commit")
        try G.write(dir, "b.txt", "left uncommitted\n")
        let closed = try #require(await store.endTurn(SessionID("s1"), repoRoot: dir.path))
        let resolved = try #require(try await store.resolve(.turn(closed), repoRoot: dir.path))
        #expect(resolved.move == nil && resolved.whole == nil)
        #expect(try await Self.paths(store, resolved.pair) == ["a.txt", "b.txt"])
    }

    @Test func anAmendOnTheSameBranchHasNotMoved() async throws {
        let (repo, dir, store) = try await Self.twoBranches()
        _ = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "amend", at: Date().addingTimeInterval(-60))
        try G.write(dir, "a.txt", "one\namended\n")
        try G.sh(dir, ["add", "-A"])
        try await repo.commit(message: "", amend: true)
        let closed = try #require(await store.endTurn(SessionID("s1"), repoRoot: dir.path))
        let resolved = try #require(try await store.resolve(.turn(closed), repoRoot: dir.path))
        #expect(resolved.move == nil)
        #expect(try await Self.paths(store, resolved.pair) == ["a.txt"])
    }

    @Test func aPullOfOlderCommitsIsAMove() async throws {
        let (_, dir, store) = try await Self.twoBranches()
        _ = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "pull")
        try G.sh(dir, ["merge", "-q", "--ff-only", "feature"])   // what a fast-forward pull does to the checkout
        try G.write(dir, "a.txt", "one\nafter the pull\n")
        let closed = try #require(await store.endTurn(SessionID("s1"), repoRoot: dir.path))
        #expect(closed.baseBranch == closed.headBranch)
        let resolved = try #require(try await store.resolve(.turn(closed), repoRoot: dir.path))
        #expect(resolved.move != nil && resolved.move?.changedBranch == false)
        #expect(try await Self.paths(store, resolved.pair) == ["a.txt"])
    }

    @Test func theSessionScopeTakesAMoveOutToo() async throws {
        let (_, dir, store) = try await Self.twoBranches()
        let session = SessionID("s1")
        await store.beginSession(session, repoRoot: dir.path)
        try G.sh(dir, ["checkout", "-q", "feature"])
        try G.write(dir, "f3.txt", "3\nsession edit\n")
        let resolved = try #require(try await store.resolve(.session(session), repoRoot: dir.path))
        #expect(try await Self.paths(store, resolved.pair) == ["f3.txt"])
        #expect(try await store.resolve(.session(SessionID("never-started")), repoRoot: dir.path) == nil)
    }

    @Test func turnsRecordedBeforeCommitsWereKeptStillResolve() async throws {
        let (_, dir, store) = try await Self.twoBranches()
        var turn = try #require(await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "old"))
        try G.sh(dir, ["checkout", "-q", "feature"])
        turn = try #require(await store.endTurn(SessionID("s1"), repoRoot: dir.path))
        turn.baseCommit = nil; turn.headCommit = nil; turn.baseBranch = nil; turn.headBranch = nil
        let resolved = try #require(try await store.resolve(.turn(turn), repoRoot: dir.path))
        #expect(resolved.move == nil && resolved.pair.base == turn.baseTree, "with nothing to go on, the pair is the snapshots")

        let legacy = #"{"sessionId":"s","repoRoot":"/r","index":1,"startedAt":"2026-09-01T00:00:00Z","baseTree":"aaa","headTree":"bbb"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(TurnSnapshot.self, from: Data(legacy.utf8)).baseCommit == nil)
    }

    // MARK: Other sessions

    @Test func aTurnKnowsAnotherSessionWasWritingToo() async throws {
        let (repo, dir, store, _) = try SnapshotTests.makeStore()
        try await Self.commit(repo, dir, ["a.txt": "one\n"], "initial")
        let start = Date()
        let mine = try #require(await store.beginTurn(SessionID("mine"), repoRoot: dir.path, prompt: "mine", at: start))
        #expect(await store.sessionsOverlapping(mine) == 0)

        _ = await store.beginTurn(SessionID("theirs"), repoRoot: dir.path, prompt: "theirs", at: start.addingTimeInterval(1))
        try G.write(dir, "b.txt", "theirs\n")
        _ = await store.endTurn(SessionID("theirs"), repoRoot: dir.path, at: start.addingTimeInterval(2))
        let closed = try #require(await store.endTurn(SessionID("mine"), repoRoot: dir.path, at: start.addingTimeInterval(3)))
        #expect(await store.sessionsOverlapping(closed) == 1)

        // A session that only asked a question changed nothing, and one that ran afterwards did not overlap.
        _ = await store.beginTurn(SessionID("later"), repoRoot: dir.path, prompt: "later", at: start.addingTimeInterval(10))
        try G.write(dir, "c.txt", "later\n")
        _ = await store.endTurn(SessionID("later"), repoRoot: dir.path, at: start.addingTimeInterval(11))
        #expect(await store.sessionsOverlapping(closed) == 1)
    }
}
