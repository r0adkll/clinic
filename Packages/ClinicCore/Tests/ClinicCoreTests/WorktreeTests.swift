import Foundation
import Testing
@testable import ClinicCore

// ADR-118. The CLI behaviour these rely on — `fresh` branches from origin/HEAD, `head` from HEAD, a
// second `--settings` replaces the first, `-w <name>` adopts an existing directory — was checked by
// hand against claude 2.1.268 on 2026-09-10; no test here runs `claude`.

@Suite struct WorktreeBaseTests {
    @Test func rawValuesRoundTrip() throws {
        for base in [WorktreeBase.defaultBranch, .currentBranch, .branch("origin/release/2.0")] {
            #expect(WorktreeBase(rawValue: base.rawValue) == base)
            let back = try JSONDecoder().decode(WorktreeBase.self, from: JSONEncoder().encode(base))
            #expect(back == base)
        }
        #expect(WorktreeBase(rawValue: "branch:") == nil)
        #expect(WorktreeBase(rawValue: "nonsense") == nil)
    }

    @Test func cliBaseRefIsAlwaysExplicit() {
        #expect(WorktreeBase.defaultBranch.cliBaseRef == "fresh")
        #expect(WorktreeBase.currentBranch.cliBaseRef == "head")
        #expect(WorktreeBase.branch("develop").cliBaseRef == "head")
        #expect(WorktreeBase.branch("develop").createsWorktree && !WorktreeBase.currentBranch.createsWorktree)
    }

    @Test func stateKeepsPerProjectBasesAndToleratesBadOnes() throws {
        var state = ClinicState()
        state.worktreeBaseByProject["/p"] = .branch("develop")
        state.worktreeBaseByProject["/q"] = .currentBranch
        let back = try JSONDecoder().decode(ClinicState.self, from: JSONEncoder().encode(state))
        #expect(back.worktreeBaseByProject == state.worktreeBaseByProject)
        let bad = try JSONDecoder().decode(ClinicState.self, from: Data(#"{"worktreeBaseByProject":{"/p":"???"}}"#.utf8))
        #expect(bad.worktreeBaseByProject.isEmpty)
    }

    @Test func hookSettingsCarryTheBaseRef() throws {
        let data = try HookSettings.json(helperPath: "/h", socketPath: "/s", worktreeBaseRef: "head")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((root["worktree"] as? [String: String])?["baseRef"] == "head")
        #expect(root["hooks"] != nil)
        let plain = try #require(try JSONSerialization.jsonObject(with: HookSettings.json(helperPath: "/h", socketPath: "/s")) as? [String: Any])
        #expect(plain["worktree"] == nil)
    }
}

@Suite struct WorktreePlanTests {
    @Test func typedNameIsKept() {
        let plan = WorktreePlan.make(ref: "develop", name: "  fix-login ", repoRoot: "/r", suffix: "abcd", exists: { _ in false })
        #expect(plan == WorktreePlan(name: "fix-login", path: "/r/.claude/worktrees/fix-login", branch: "worktree-fix-login", ref: "develop", create: true))
    }

    @Test func emptyNameIsNamedAfterTheRef() {
        #expect(WorktreePlan.make(ref: "origin/release/2.0", name: "", repoRoot: "/r", suffix: "k3x9", exists: { _ in false }).name == "origin-release-2-0-k3x9")
        #expect(WorktreePlan.make(ref: "🔥", name: "", repoRoot: "/r", suffix: "k3x9", exists: { _ in false }).name == "worktree-k3x9")
    }

    @Test func anExistingDirectoryIsReopenedNotCreated() {
        let plan = WorktreePlan.make(ref: "develop", name: "old", repoRoot: "/r", suffix: "", exists: { $0 == "/r/.claude/worktrees/old" })
        #expect(!plan.create)
    }

    @Test func suffixIsFourSafeCharacters() {
        let s = WorktreePlan.randomSuffix()
        #expect(s.count == 4 && s.allSatisfy { $0.isLowercase || $0.isNumber })
    }
}

@Suite struct GitBranchesTests {
    @Test func localFirstRemotesWithoutALocalTwin() {
        let out = """
        refs/heads/feature
        refs/remotes/origin/HEAD
        refs/remotes/origin/main
        refs/heads/main
        refs/remotes/origin/release/2.0
        refs/remotes/upstream/feature
        """
        #expect(GitBranches.parse(out) == GitBranches(local: ["feature", "main"], remote: ["origin/release/2.0"]))
    }
}

@Suite(.serialized) struct WorktreeCreationTests {
    @Test func createsFromABranchAndCopiesIncludes() async throws {
        let (repo, dir) = try GitRepositoryTests.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try GitRepositoryTests.write(dir, ".gitignore", ".env\n.claude/\nbuild/\n")
        try GitRepositoryTests.write(dir, "tracked.txt", "t\n")
        try GitRepositoryTests.sh(dir, ["add", "."])
        try GitRepositoryTests.sh(dir, ["commit", "-q", "-m", "main-1"])
        try GitRepositoryTests.sh(dir, ["checkout", "-q", "-b", "develop"])
        try GitRepositoryTests.write(dir, "develop.txt", "d\n")
        try GitRepositoryTests.sh(dir, ["add", "."])
        try GitRepositoryTests.sh(dir, ["commit", "-q", "-m", "develop-1"])
        try GitRepositoryTests.sh(dir, ["checkout", "-q", "main"])
        // Ignored and included; ignored but not included; included but tracked.
        try GitRepositoryTests.write(dir, ".worktreeinclude", ".env\ntracked.txt\n")
        try GitRepositoryTests.write(dir, ".env", "SECRET=1\n")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("build"), withIntermediateDirectories: true)
        try GitRepositoryTests.write(dir, "build/out.o", "x")

        let branches = await repo.branches()
        #expect(Set(branches.local) == ["main", "develop"] && branches.remote.isEmpty)

        let plan = WorktreePlan.make(ref: "develop", name: "from-dev", repoRoot: dir.path, suffix: "")
        try await repo.createWorktree(plan)
        let wt = URL(fileURLWithPath: plan.path)
        #expect(FileManager.default.fileExists(atPath: wt.appendingPathComponent("develop.txt").path))
        #expect(try String(contentsOf: wt.appendingPathComponent(".env"), encoding: .utf8) == "SECRET=1\n")
        #expect(!FileManager.default.fileExists(atPath: wt.appendingPathComponent("build/out.o").path))
        let list = try await repo.worktrees()
        #expect(list.contains { $0.branch == "worktree-from-dev" })
        // The branch doesn't track its start point.
        let upstream = await GitProcess.run(["rev-parse", "--abbrev-ref", "worktree-from-dev@{upstream}"], in: dir.path)
        #expect(upstream.status != 0)

        // Reusing the name is a no-op, as `-w <name>` would reopen it.
        let again = WorktreePlan.make(ref: "main", name: "from-dev", repoRoot: dir.path, suffix: "")
        #expect(!again.create)
        try await repo.createWorktree(again)

        // A clash with an existing branch surfaces git's own message.
        try GitRepositoryTests.sh(dir, ["branch", "worktree-taken"])
        await #expect(throws: GitError.self) {
            try await repo.createWorktree(WorktreePlan.make(ref: "develop", name: "taken", repoRoot: dir.path, suffix: ""))
        }
    }
}
