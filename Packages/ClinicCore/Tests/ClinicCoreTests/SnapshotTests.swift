import Foundation
import Testing
@testable import ClinicCore

/// ADR-080: turn snapshots are git trees written outside the repository.
@Suite(.serialized) struct SnapshotTests {
    typealias G = GitRepositoryTests

    /// A repo plus a store whose snapshot directory is its own temp dir, so nothing here can touch
    /// the real Application Support.
    static func makeStore() throws -> (GitRepository, URL, SnapshotStore, URL) {
        let (repo, dir) = try G.makeRepo()
        let snapDir = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-snap-\(UUID().uuidString)")
        return (repo, dir, SnapshotStore(directory: snapDir), snapDir)
    }

    static func objectCount(_ dir: URL) -> Int {
        let objects = dir.appendingPathComponent(".git/objects")
        guard let e = FileManager.default.enumerator(at: objects, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        return e.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }.count
    }

    // MARK: The mechanism

    @Test func snapshotWritesNothingIntoTheRepository() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, "a.txt", "one\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")

        let before = Self.objectCount(dir)

        try G.write(dir, "a.txt", "one\ntwo\n")
        try G.write(dir, "untracked.txt", "fresh\n")
        let scratch = await store.scratch(for: dir.path)
        let tree = try await repo.writeSnapshotTree(scratch)

        #expect(tree.count == 40)
        // `<=`, not `==`: `objectCount` counts *files* under .git/objects, and git may pack loose
        // objects or write a commit-graph between the two readings, which lowers the count without
        // anything having been added. Requiring equality made this flaky on CI (4 before, 3 after).
        #expect(Self.objectCount(dir) <= before, "snapshotting must not add objects to the user's repo")
        // The direct form of the same claim, immune to how git chooses to store things: the tree we
        // wrote must not be reachable in the user's repository at all.
        let probe = await GitProcess.run(["cat-file", "-e", tree], in: dir.path)
        #expect(probe.status != 0, "the snapshot tree must not exist in the user's repo")

        // The user's own index is untouched: a.txt is still unstaged and untracked.txt untracked.
        let status = try await repo.status()
        #expect(status.files.first { $0.path == "a.txt" }?.index == nil)
        #expect(status.files.first { $0.path == "a.txt" }?.worktree == .modified)
        #expect(status.files.first { $0.path == "untracked.txt" }?.isUntracked == true)

        // The blobs went to Clinic's store instead.
        let ours = try FileManager.default.subpathsOfDirectory(atPath: scratch.objectDirectory)
        #expect(!ours.isEmpty)
    }

    @Test func snapshotDiffSpansAddsEditsDeletesAndUntracked() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, "keep.txt", G.lines(10))
        try G.write(dir, "gone.txt", "delete me\n")
        try await repo.stage(paths: ["keep.txt", "gone.txt"])
        try await repo.commit(message: "initial")

        let scratch = await store.scratch(for: dir.path)
        let base = try await repo.writeSnapshotTree(scratch)

        try G.write(dir, "keep.txt", G.lines(10, changing: [3: "line three changed"]))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone.txt"))
        try G.write(dir, "added.txt", "brand new\n")
        let head = try await repo.writeSnapshotTree(scratch)

        #expect(base != head)
        let diff = try await repo.diff(from: base, to: head, scratch: scratch)
        let paths = Set(diff.files.map(\.path))
        #expect(paths == ["keep.txt", "gone.txt", "added.txt"])
        #expect(diff.files.first { $0.path == "added.txt" }?.isNew == true)
        #expect(diff.files.first { $0.path == "gone.txt" }?.isDeleted == true)
        #expect(diff.files.first { $0.path == "keep.txt" }?.additions == 1)
    }

    @Test func snapshotHonoursGitignoreAndIsStableWhenNothingChanges() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, ".gitignore", "build/\n")
        try await repo.stage(paths: [".gitignore"])
        try await repo.commit(message: "initial")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("build"), withIntermediateDirectories: true)
        try G.write(dir, "build/out.o", "noise\n")

        let scratch = await store.scratch(for: dir.path)
        let first = try await repo.writeSnapshotTree(scratch)
        try G.write(dir, "build/out.o", "different noise\n")
        let second = try await repo.writeSnapshotTree(scratch)
        #expect(first == second, "ignored files must not move the tree")
        #expect(try await repo.diff(from: first, to: second, scratch: scratch).files.isEmpty)
    }

    /// Commits inside a turn are irrelevant: the tree pair still states the net change on disk.
    @Test func snapshotDiffIgnoresCommitsMadeInBetween() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, "a.txt", "one\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")

        let scratch = await store.scratch(for: dir.path)
        let base = try await repo.writeSnapshotTree(scratch)

        try G.write(dir, "a.txt", "one\ntwo\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "mid-turn commit")
        try G.write(dir, "a.txt", "one\ntwo\nthree\n")
        let head = try await repo.writeSnapshotTree(scratch)

        let diff = try await repo.diff(from: base, to: head, scratch: scratch)
        #expect(diff.files.map(\.path) == ["a.txt"])
        #expect(diff.files[0].additions == 2)
    }

    @Test func treeOfRefResolvesCommits() async throws {
        let (repo, dir, _, _) = try Self.makeStore()
        try G.write(dir, "a.txt", "one\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")
        let head = try await repo.tree(of: "HEAD")
        #expect(head.count == 40)
        #expect(try await repo.diff(from: head, to: head, scratch: nil).files.isEmpty)
    }

    // MARK: Branch and commit scopes (ADR-080)

    @Test func numstatTotals() {
        #expect(DiffStat(numstat: "").isEmpty)
        let stat = DiffStat(numstat: "3\t1\ta.txt\n10\t0\tb.txt\n-\t-\timg.png\n")
        #expect(stat.files == 3 && stat.additions == 13 && stat.deletions == 1, "binary files count but add no lines")
    }

    @Test func branchScopeDiffsFromTheMergeBase() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, "a.txt", G.lines(5))
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")
        #expect(await repo.branchBaseRef() == nil, "on the default branch there is nothing to compare against")

        try G.sh(dir, ["checkout", "-q", "-b", "feature"])
        try G.write(dir, "a.txt", G.lines(5, changing: [2: "changed on the branch"]))
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "first")
        try G.write(dir, "b.txt", "second commit\n")
        try await repo.stage(paths: ["b.txt"])
        try await repo.commit(message: "second")

        let base = try #require(await repo.branchBaseRef())
        #expect(base == "main")

        // Whole branch: both commits.
        let branch = try await repo.diff(branchFrom: base)
        #expect(Set(branch.files.map(\.path)) == ["a.txt", "b.txt"])

        // One commit: only its own change.
        let commits = try await repo.commits()
        #expect(commits.map(\.subject) == ["second", "first"])
        let second = try await repo.diff(commit: commits[0].sha)
        #expect(second.files.map(\.path) == ["b.txt"])
        let first = try await repo.diff(commit: commits[1].sha)
        #expect(first.files.map(\.path) == ["a.txt"])

        // The branch diff ignores what happened on main after the split.
        try G.sh(dir, ["checkout", "-q", "main"])
        try G.write(dir, "c.txt", "only on main\n")
        try await repo.stage(paths: ["c.txt"])
        try await repo.commit(message: "main moves on")
        try G.sh(dir, ["checkout", "-q", "feature"])
        let after = try await repo.diff(branchFrom: base)
        #expect(Set(after.files.map(\.path)) == ["a.txt", "b.txt"], "a...b must not show the base branch's own commits")
        _ = store
    }

    @Test func statMatchesThePatch() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, "a.txt", G.lines(10))
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")

        let scratch = await store.scratch(for: dir.path)
        let base = try await repo.writeSnapshotTree(scratch)
        try G.write(dir, "a.txt", G.lines(10, changing: [4: "changed"], inserting: [7: ["extra"]]))
        try G.write(dir, "new.txt", "one\ntwo\n")
        let head = try await repo.writeSnapshotTree(scratch)

        let stat = try await repo.stat(from: base, to: head, scratch: scratch)
        let patch = try await repo.diff(from: base, to: head, scratch: scratch)
        #expect(stat.files == patch.files.count)
        #expect(stat.additions == patch.files.reduce(0) { $0 + $1.additions })
        #expect(stat.deletions == patch.files.reduce(0) { $0 + $1.deletions })
        #expect(try await repo.stat(from: base, to: base, scratch: scratch).isEmpty)
    }

    // MARK: The store

    @Test func turnLifecycleRecordsBaseAndHead() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, "a.txt", "one\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")

        let baseline = await store.beginSession(SessionID("s1"), repoRoot: dir.path)
        #expect(baseline != nil)

        let turn = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "add a feature\nwith detail")
        #expect(turn?.index == 1)
        #expect(turn?.prompt == "add a feature", "only the first line labels a turn")
        #expect(turn?.isInFlight == true)

        try G.write(dir, "a.txt", "one\ntwo\n")
        // The in-flight turn already diffs against the live worktree.
        let live = try await store.diff(turn: #require(turn))
        #expect(live.files.map(\.path) == ["a.txt"])

        let closed = await store.endTurn(SessionID("s1"), repoRoot: dir.path)
        #expect(closed?.headTree != nil && closed?.isInFlight == false)
        #expect(closed?.baseTree != closed?.headTree)
        #expect(try await store.diff(turn: #require(closed)).files.map(\.path) == ["a.txt"])

        // Session scope spans the whole attach.
        let session = try await store.diffSinceSessionStart(SessionID("s1"), repoRoot: dir.path)
        #expect(session?.files.map(\.path) == ["a.txt"])
    }

    @Test func aSecondPromptClosesAnAbandonedTurn() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, "a.txt", "one\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")

        _ = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "first")
        try G.write(dir, "a.txt", "one\ntwo\n")
        let second = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "second")
        #expect(second?.index == 2)

        let snaps = await store.snapshots(session: SessionID("s1"), repoRoot: dir.path)
        #expect(snaps.turns.count == 2)
        #expect(snaps.turns[0].isInFlight == false, "an interrupted turn is closed where it stood")
        #expect(snaps.turns[0].headTree == second?.baseTree)
        #expect(snaps.openTurn?.index == 2)
        #expect(snaps.recentTurns.map(\.index) == [2, 1])
    }

    @Test func anEmptyTurnHasIdenticalTrees() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, "a.txt", "one\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")
        _ = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "explain this code")
        let closed = await store.endTurn(SessionID("s1"), repoRoot: dir.path)
        #expect(closed?.isEmpty == true)
        #expect(try await store.diff(turn: #require(closed)).files.isEmpty)
    }

    @Test func endTurnWithoutAnOpenTurnIsANoOp() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, "a.txt", "one\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")
        #expect(await store.endTurn(SessionID("s1"), repoRoot: dir.path) == nil)
        #expect(await store.snapshots(session: SessionID("s1"), repoRoot: dir.path).turns.isEmpty)
    }

    @Test func turnsPersistAcrossStoreInstances() async throws {
        let (repo, dir, store, snapDir) = try Self.makeStore()
        try G.write(dir, "a.txt", "one\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")
        _ = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "first")
        try G.write(dir, "a.txt", "one\ntwo\n")
        _ = await store.endTurn(SessionID("s1"), repoRoot: dir.path)

        let reopened = SnapshotStore(directory: snapDir)
        let snaps = await reopened.snapshots(session: SessionID("s1"), repoRoot: dir.path)
        #expect(snaps.turns.count == 1 && snaps.turns[0].prompt == "first")
        #expect(try await reopened.diff(turn: snaps.turns[0]).files.map(\.path) == ["a.txt"],
                "trees written by an earlier run must still resolve")
    }

    /// Two sessions in the same repo share one object store; a different repo gets its own.
    @Test func sessionsShareTheRepoStoreAndLineagesStaySeparate() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, "a.txt", "one\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")
        _ = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "one")
        _ = await store.beginTurn(SessionID("s2"), repoRoot: dir.path, prompt: "two")

        let a = await store.scratch(for: dir.path)
        let b = await store.scratch(for: dir.path + "/../elsewhere")
        #expect(a.objectDirectory != b.objectDirectory)
        #expect(await store.snapshots(session: SessionID("s1"), repoRoot: dir.path).turns.count == 1)
        #expect(await store.snapshots(session: SessionID("s2"), repoRoot: dir.path).turns.count == 1)
        #expect(await store.snapshots(session: SessionID("s1"), repoRoot: dir.path + "/../elsewhere").turns.isEmpty,
                "a change of repo root starts a new lineage")
    }

    @Test func pruneDropsStaleReposAndKeepsLiveOnes() async throws {
        let (repo, dir, store, snapDir) = try Self.makeStore()
        try G.write(dir, "a.txt", "one\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")
        _ = await store.beginTurn(SessionID("s1"), repoRoot: dir.path, prompt: "one")
        #expect(await store.diskUsage() > 0)

        // Nothing is stale yet, whether it is live or not.
        #expect(await store.prune(keeping: [dir.path]).isEmpty)
        #expect(await store.prune().isEmpty)

        // Age the repo directory past the retention window.
        let repoDir = snapDir.appendingPathComponent(SnapshotStore.repoKey(dir.path))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)], ofItemAtPath: repoDir.path)
        #expect(await store.prune(keeping: [dir.path]).isEmpty, "a live repo is never pruned")
        #expect(await store.prune() == [SnapshotStore.repoKey(dir.path)])
        #expect(await store.snapshots(session: SessionID("s1"), repoRoot: dir.path).turns.isEmpty)
    }

    // MARK: Hook routing (ADR-080)

    static func hook(_ name: String, source: String? = nil, prompt: String? = nil) -> HookEvent {
        HookEvent(hookEventName: name, sessionId: SessionID("s1"), source: source, prompt: prompt)
    }

    @Test func triggerMapsTheTurnBoundaryEvents() {
        #expect(SnapshotTrigger(event: Self.hook("SessionStart", source: "startup")) == .beginSession)
        #expect(SnapshotTrigger(event: Self.hook("SessionStart", source: "resume")) == .beginSession)
        #expect(SnapshotTrigger(event: Self.hook("SessionStart")) == .beginSession, "an unlabelled start is a startup")
        #expect(SnapshotTrigger(event: Self.hook("UserPromptSubmit", prompt: "do a thing")) == .beginTurn(prompt: "do a thing"))
        #expect(SnapshotTrigger(event: Self.hook("Stop")) == .endTurn)
        #expect(SnapshotTrigger(event: Self.hook("StopFailure")) == .endTurn)
        #expect(SnapshotTrigger(event: Self.hook("SessionEnd")) == .endTurn)
    }

    @Test func compactAndClearRestartsAreNotNewAttachments() {
        for source in ["compact", "clear", "fork"] {
            #expect(SnapshotTrigger(event: Self.hook("SessionStart", source: source)) == nil,
                    "\(source) must not move the session baseline")
        }
    }

    @Test func everythingElseIsIgnored() {
        for name in ["PreToolUse", "PermissionRequest", "PermissionDenied", "Notification", "PostModelSwitch", "CwdChanged", "WorktreeCreate"] {
            #expect(SnapshotTrigger(event: Self.hook(name)) == nil)
        }
    }

    @Test func recordDrivesTheWholeLifecycleFromHookEvents() async throws {
        let (repo, dir, store, _) = try Self.makeStore()
        try G.write(dir, "a.txt", "one\n")
        try await repo.stage(paths: ["a.txt"])
        try await repo.commit(message: "initial")

        let session = SessionID("s1")
        for event in [Self.hook("SessionStart", source: "startup"),
                      Self.hook("UserPromptSubmit", prompt: "add two\nplease"),
                      Self.hook("SessionStart", source: "compact")] {
            guard let trigger = SnapshotTrigger(event: event) else { continue }
            await store.record(trigger, session: session, repoRoot: dir.path)
        }
        try G.write(dir, "a.txt", "one\ntwo\n")
        await store.record(.endTurn, session: session, repoRoot: dir.path)

        let snaps = await store.snapshots(session: session, repoRoot: dir.path)
        #expect(snaps.turns.count == 1, "the compact restart must not have opened a turn")
        #expect(snaps.turns[0].prompt == "add two")
        #expect(snaps.turns[0].isInFlight == false)
        #expect(try await store.diff(turn: snaps.turns[0]).files.map(\.path) == ["a.txt"])
    }

    @Test func hookEventDecodesThePrompt() throws {
        let json = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"S1","prompt":"rewrite the parser","cwd":"/tmp"}"#.utf8)
        let event = try HookEvent.decode(json)
        #expect(event.prompt == "rewrite the parser")
        #expect(SnapshotTrigger(event: event) == .beginTurn(prompt: "rewrite the parser"))
    }

    @Test func firstLineTrimsAndBounds() {
        #expect(SnapshotStore.firstLine(nil) == nil)
        #expect(SnapshotStore.firstLine("   \n\n") == nil)
        #expect(SnapshotStore.firstLine("\n  hello  \nworld") == "hello")
        #expect(SnapshotStore.firstLine(String(repeating: "x", count: 300))?.count == 201)
    }
}
