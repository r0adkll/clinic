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

    @Test func mcpConfigFlagAndFile() throws {
        var l = ClaudeLaunch(mode: .new(id: id), settingsFilePath: "/tmp/h.json")
        l.mcpConfigPath = "/tmp/mcp/\(id.rawValue).json"
        #expect(l.arguments.suffix(2) == ["--mcp-config", "/tmp/mcp/\(id.rawValue).json"])
        let data = try MCPConfig.json(helperPath: "/Applications/Clinic.app/Contents/MacOS/clinic-hook", socketPath: "/tmp/mcp.sock", sessionId: id)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let server = try #require((root["mcpServers"] as? [String: Any])?["clinic"] as? [String: Any])
        #expect(server["args"] as? [String] == ["mcp", "/tmp/mcp.sock", id.rawValue])
        #expect(MCPToolSpec.all.map(\.name).contains("notify_user"))
        #expect(MCPToolSpec.all.first { $0.name == "run_in_terminal" }?.defaultEnabled == false)
    }

    @Test func worktreeNameIsPassed() {
        var l = ClaudeLaunch(mode: .new(id: id), worktree: true, settingsFilePath: "/tmp/h.json")
        l.worktreeName = "feature-x"
        #expect(l.arguments.contains("-w") && l.arguments[l.arguments.firstIndex(of: "-w")! + 1] == "feature-x")
    }

    @Test func continueLine() {
        #expect(ClaudeLaunch(mode: .continueLast, settingsFilePath: "/tmp/h.json").arguments == ["--continue", "--settings", "/tmp/h.json"])
    }

    @Test func attachLine() {
        let l = ClaudeLaunch(mode: .attach(agentId: "abc-123"), model: "opus", settingsFilePath: "/tmp/h.json")
        #expect(l.shellLine == "claude attach abc-123\n")
    }

    @Test func parsesAgentsJSON() {
        let json = #"[{"pid":18649,"cwd":"/x","kind":"background","startedAt":1788794985237,"sessionId":"48f2e763-c9c5-41d7-a2e1-610331040dd3","id":"agent-1","name":"clinic-77","status":"busy","state":"needs_input","waitingFor":"permission"},{"cwd":"/y","kind":"interactive","startedAt":"2026-09-07T10:00:00Z","status":"idle"},{"nope":true}]"#
        let agents = BackgroundAgent.parse(Data(json.utf8))
        #expect(agents.count == 1)
        #expect(agents[0].id == "agent-1" && agents[0].isBackground && agents[0].needsAttention && agents[0].isRunning)
        #expect(agents[0].startedAt.map { Calendar.current.component(.year, from: $0) } == 2026)
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
