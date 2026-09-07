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
        #expect(SessionNaming.displayName(for: s) == "abcdef01")
        s.firstPrompt = "one two three four five six seven eight nine ten eleven twelve"
        #expect(SessionNaming.displayName(for: s) == "one two three four five six seven eight nine ten…")
        s.aiTitle = "AI title"
        #expect(SessionNaming.displayName(for: s) == "AI title")
        s.customTitle = "Custom"
        #expect(SessionNaming.displayName(for: s) == "Custom")
        #expect(SessionNaming.displayName(for: s, manualName: "Manual") == "Manual")
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
