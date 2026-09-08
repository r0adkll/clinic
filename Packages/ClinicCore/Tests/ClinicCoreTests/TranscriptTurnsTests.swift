import Foundation
import Testing
@testable import ClinicCore

@Suite struct TranscriptTurnsTests {
    @Test func buildsTurnsAndStats() {
        var f = TranscriptFixture()
        f.user("<system-reminder>ignore</system-reminder>")
        f.user("Fix the build", at: "2026-09-07T10:00:00.000Z")
        f.raw(#"{"type":"assistant","timestamp":"2026-09-07T10:00:05.000Z","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":300,"cache_creation_input_tokens":40},"content":[{"type":"thinking","thinking":""},{"type":"text","text":"On it."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift build\nswift test"}}]}}"#)
        f.raw(#"{"type":"user","timestamp":"2026-09-07T10:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Build complete!","is_error":false}]}}"#)
        f.raw(#"{"type":"assistant","timestamp":"2026-09-07T10:00:09.000Z","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":7},"content":[{"type":"tool_use","id":"toolu_2","name":"mcp__clinic__notify_user","input":{"message":"done"}},{"type":"text","text":"Done."}]}}"#)
        f.costState(1.25)
        let r = TranscriptTurns.parse(f.data)
        let kinds = r.turns.map { t -> String in switch t { case .user: "user"; case .assistant: "assistant"; case .toolUse: "tool"; case .toolResult: "result" } }
        #expect(kinds == ["user", "assistant", "tool", "result", "tool", "assistant"])
        if case .toolUse(let name, let summary, _, _) = r.turns[2] { #expect(name == "Bash" && summary == "swift build") } else { Issue.record("expected tool use") }
        #expect(r.stats.userMessages == 1 && r.stats.assistantMessages == 2 && r.stats.thinkingBlocks == 1)
        #expect(r.stats.toolCalls == ["Bash": 1, "mcp__clinic__notify_user": 1])
        #expect(r.stats.mcpServers == ["clinic"])
        #expect(r.stats.models == ["claude-opus-5"])
        #expect(r.stats.inputTokens == 15 && r.stats.outputTokens == 27 && r.stats.cacheReadTokens == 300 && r.stats.cacheCreationTokens == 40)
        #expect(r.stats.totalCostUSD == 1.25)
        #expect(r.stats.duration == 9)
    }

    @Test func summariesPerTool() {
        #expect(TranscriptTurns.toolSummary(name: "Read", input: ["file_path": "/a/b.swift"]) == "/a/b.swift")
        #expect(TranscriptTurns.toolSummary(name: "Grep", input: ["pattern": "foo", "path": "src"]) == "foo in src")
        #expect(TranscriptTurns.toolSummary(name: "Custom", input: ["x": 1, "long": "hello world", "short": "hi"]) == "hello world")
        #expect(TranscriptTurns.toolSummary(name: "Bash", input: ["command": String(repeating: "x", count: 200)]).count == 161)
    }
}
