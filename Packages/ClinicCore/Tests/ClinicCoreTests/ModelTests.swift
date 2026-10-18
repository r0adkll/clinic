import Foundation
import Testing
@testable import ClinicCore

@Suite struct ModelTests {
    @Test func worktreeFoldsIntoRepo() {
        #expect(ProjectGrouping.projectPath(forCwd: "/Users/me/repo/.claude/worktrees/feat/sub") == "/Users/me/repo")
        #expect(ProjectGrouping.projectPath(forCwd: "/Users/me/repo") == "/Users/me/repo")
    }

    @Test func namingPrecedence() {
        var s = SessionSummary(id: SessionID("abcdef01-0000-0000-0000-000000000000"), transcriptPath: "p")
        #expect(SessionNaming.displayName(for: s) == "New session")
        s.firstPrompt = "one two three four five six seven eight nine ten eleven twelve"
        #expect(SessionNaming.displayName(for: s) == "one two three four five six seven eight nine ten…")
        s.aiTitle = "AI title"
        #expect(SessionNaming.displayName(for: s) == "AI title")
        s.customTitle = "Custom"
        #expect(SessionNaming.displayName(for: s) == "Custom")
        #expect(SessionNaming.displayName(for: s, manualName: "Manual") == "Manual")
    }

    /// `attach_pr`'s PRs survive a rescan by being re-applied after the transcript's own (ADR-228).
    @Test func attachedPullRequestsFollowTheTranscriptsOwn() throws {
        let a = try #require(PullRequestRef(url: URL(string: "https://github.com/o/r/pull/1")!))
        let b = try #require(PullRequestRef(url: URL(string: "https://github.com/o/r/pull/2")!))
        let c = try #require(PullRequestRef(url: URL(string: "https://github.com/o/r/pull/3")!))
        var s = SessionSummary(id: SessionID("abcdef01-0000-0000-0000-000000000000"), transcriptPath: "p")
        s.pullRequests = [a, b]
        // One the transcript also names keeps its place; a new one goes last.
        #expect(s.withAttached([b, c]).pullRequests.map(\.number) == [1, 2, 3])
        #expect(s.withAttached([]).pullRequests == s.pullRequests)
    }

    @Test func stateKeepsAttachedPullRequests() throws {
        var state = ClinicState()
        let id = SessionID.generate()
        state.attachedPullRequests[id] = [try #require(PullRequestRef(url: URL(string: "https://github.com/o/r/pull/7")!))]
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(ClinicState.self, from: e.encode(state))
        #expect(back.attachedPullRequests == state.attachedPullRequests)
        // Older state files have no key.
        #expect(try d.decode(ClinicState.self, from: Data(#"{"version":1}"#.utf8)).attachedPullRequests.isEmpty)
    }

    @Test func encodedProjectDirectoryName() {
        #expect(ClaudePaths.encodedProjectDirectoryName(for: "/Users/r0adkll/SoftwareProjects/main/clinic") == "-Users-r0adkll-SoftwareProjects-main-clinic")
        #expect(ClaudePaths.encodedProjectDirectoryName(for: "/private/tmp/a_b.c") == "-private-tmp-a-b-c")
    }

    @Test func configDirHonoursEnv() {
        let p = ClaudePaths(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"], home: URL(fileURLWithPath: "/Users/x"))
        #expect(p.projectsDirectory.path == "/tmp/cc/projects")
        let d = ClaudePaths(environment: [:], home: URL(fileURLWithPath: "/Users/x"))
        #expect(d.projectsDirectory.path == "/Users/x/.claude/projects")
    }
}
