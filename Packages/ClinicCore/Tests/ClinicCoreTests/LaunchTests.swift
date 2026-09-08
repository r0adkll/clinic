import Foundation
import Testing
@testable import ClinicCore

@Suite struct LaunchTests {
    let id = SessionID("11111111-2222-3333-4444-555555555555")

    @Test func newSessionLine() {
        let l = ClaudeLaunch(mode: .new(id: id), model: "opus", worktree: true, settingsFilePath: "/Users/me/Library/Application Support/Clinic/hooks.json")
        #expect(l.shellLine == "claude --session-id 11111111-2222-3333-4444-555555555555 --model opus -w --settings '/Users/me/Library/Application Support/Clinic/hooks.json'\n")
    }

    @Test func resumeLineNeverPassesWorktree() {
        let l = ClaudeLaunch(mode: .resume(id: id, fork: true), worktree: true, settingsFilePath: "/tmp/h.json")
        #expect(l.arguments == ["--resume", id.rawValue, "--fork-session", "--settings", "/tmp/h.json"])
    }

    @Test func promptAndEffortAreAppended() {
        let l = ClaudeLaunch(mode: .new(id: id), model: "opus", effort: "xhigh", settingsFilePath: "/tmp/h.json", prompt: "Fix the flaky test\nthen push")
        #expect(l.arguments == ["--session-id", id.rawValue, "--model", "opus", "--effort", "xhigh", "--settings", "/tmp/h.json", "Fix the flaky test\nthen push"])
        #expect(l.shellLine.hasSuffix("'Fix the flaky test\nthen push'\n"))
        #expect(ClaudeLaunch(mode: .new(id: id), settingsFilePath: "/tmp/h.json", prompt: "   ").arguments.last == "/tmp/h.json")
    }

    @Test func shellQuoting() {
        #expect(ClaudeLaunch.shellQuote("it's") == "'it'\\''s'")
        #expect(ClaudeLaunch.shellQuote("plain-1.0") == "plain-1.0")
    }

    @Test func hookSettingsRegistersAllEvents() throws {
        let data = try HookSettings.json(helperPath: "/Applications/Clinic.app/Contents/MacOS/clinic-hook", socketPath: "/Users/me/Library/Application Support/Clinic/hook.sock")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookSettings.events))
        let entry = try #require((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(entry.first?["async"] as? Bool == true)
        #expect((entry.first?["command"] as? String)?.contains("clinic-hook '/Users/me/Library/Application Support/Clinic/hook.sock'") == true)
    }
}
