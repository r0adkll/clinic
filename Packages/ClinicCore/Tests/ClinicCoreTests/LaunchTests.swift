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
        #expect(l.arguments == ["Fix the flaky test\nthen push", "--session-id", id.rawValue, "--model", "opus", "--effort", "xhigh", "--settings", "/tmp/h.json"])
        #expect(l.shellLine.hasPrefix("claude 'Fix the flaky test\nthen push' --session-id"))
        #expect(ClaudeLaunch(mode: .new(id: id), settingsFilePath: "/tmp/h.json", prompt: "   ").arguments.first == "--session-id")
        var m = ClaudeLaunch(mode: .new(id: id), settingsFilePath: "/tmp/h.json", prompt: "Where are we?"); m.mcpConfigPath = "/tmp/mcp.json"
        #expect(m.arguments.first == "Where are we?" && m.arguments.suffix(2) == ["--mcp-config", "/tmp/mcp.json"])
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

    /// Verbatim `claude agents --json --all` output for a background session that has *finished*
    /// (captured 2026-09-09, CLI 2.1.266, while probing for ADR-095). The CLI documents `completed`,
    /// but reports `done` with `status: idle` and the process still resident — which is why this
    /// payload, not a hand-written one, is the regression test.
    @Test func finishedAgentIsNotRunning() {
        let json = #"[{"pid":55976,"id":"f20fb727","cwd":"/Users/me/clinic","kind":"background","startedAt":1788981700870,"sessionId":"f20fb727-ae40-4a55-87ac-ce6c1fe5706f","name":"clinic-automation-probe","status":"idle","state":"done"}]"#
        let agents = BackgroundAgent.parse(Data(json.utf8))
        #expect(agents.count == 1)
        let a = try! #require(agents.first)
        #expect(a.isBackground)
        #expect(!a.isRunning)        // the defect: `done` was not in the terminal set
        #expect(!a.needsAttention)
    }

    @Test func agentStateSets() {
        // A finish must announce, whatever the CLI calls it; a stop the user asked for must not.
        #expect(BackgroundAgent.announcedStates.isSuperset(of: ["done", "completed", "failed", "needs_input", "blocked"]))
        #expect(!BackgroundAgent.announcedStates.contains("stopped"))
        #expect(BackgroundAgent.terminalStates.contains("stopped"))
        // `working` is neither, so a busy agent keeps polling at the fast interval.
        #expect(!BackgroundAgent.terminalStates.contains("working"))
        #expect(BackgroundAgent(id: "x", sessionId: nil, kind: "background", status: "busy", state: "working").isRunning)
        // `status: stopped` still wins even when `state` is unknown to us.
        #expect(!BackgroundAgent(id: "x", sessionId: nil, kind: "background", status: "stopped", state: "mystery").isRunning)
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
