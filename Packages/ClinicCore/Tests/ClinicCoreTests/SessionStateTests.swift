import Foundation
import Testing
@testable import ClinicCore

@Suite struct SessionStateTests {
    let id = SessionID("11111111-2222-3333-4444-555555555555")
    func ev(_ name: String, notification: String? = nil) -> HookEvent { HookEvent(hookEventName: name, sessionId: id, notificationType: notification) }

    func run(_ events: [HookEvent], from start: SessionState = .launching) -> [SessionState] {
        var state = start; var trace: [SessionState] = []
        for e in events { if let next = SessionStateMachine.reduce(state, event: e) { state = next }; trace.append(state) }
        return trace
    }

    @Test func happyPath() {
        let trace = run([ev("SessionStart"), ev("UserPromptSubmit"), ev("PreToolUse"), ev("Stop"), ev("SessionEnd")])
        #expect(trace == [.idle, .working, .working, .idle, .exited])
    }

    @Test func permissionFlow() {
        let trace = run([ev("SessionStart"), ev("UserPromptSubmit"), ev("PermissionRequest"), ev("Notification", notification: "permission_prompt"), ev("PreToolUse"), ev("Stop")])
        #expect(trace == [.idle, .working, .waitingForPermission, .waitingForPermission, .working, .idle])
    }

    @Test func deniedReturnsToWorking() {
        let trace = run([ev("SessionStart"), ev("UserPromptSubmit"), ev("PermissionRequest"), ev("PermissionDenied")])
        #expect(trace.last == .working)
    }

    @Test func idlePromptWaitsForInput() {
        let trace = run([ev("SessionStart"), ev("Stop"), ev("Notification", notification: "idle_prompt"), ev("UserPromptSubmit")])
        #expect(trace == [.idle, .idle, .waitingForInput, .working])
    }

    @Test func ignoredEventsDoNotChangeState() {
        #expect(SessionStateMachine.reduce(.working, event: ev("PostToolUse")) == nil)
        #expect(SessionStateMachine.reduce(.working, event: ev("Notification", notification: "auth_success")) == nil)
        #expect(SessionStateMachine.reduce(.exited, event: ev("Notification", notification: "idle_prompt")) == nil)
    }

    @Test func finishedEdge() {
        #expect(SessionStateMachine.isFinishedEdge(from: .working, to: .idle))
        #expect(!SessionStateMachine.isFinishedEdge(from: .idle, to: .idle))
    }

    @Test func decodesRealPayloadShape() throws {
        let json = """
        {"session_id":"d4537350-4504-4ea2-8fb2-ab146b19add7","transcript_path":"/Users/me/.claude/projects/-x/d4537350.jsonl","cwd":"/x","hook_event_name":"SessionStart","source":"startup","extra_unknown":{"a":1}}
        """
        let e = try HookEvent.decode(Data(json.utf8))
        #expect(e.hookEventName == "SessionStart")
        #expect(e.sessionId == SessionID("d4537350-4504-4ea2-8fb2-ab146b19add7"))
        #expect(e.source == "startup")
        #expect(e.cwd == "/x")
    }

    /// The CLI's documented status line input, stamped by `clinic-hook statusline` (ADR-157).
    @Test func statusLinePayloadDecodes() throws {
        let json = #"{"hook_event_name":"StatusLine","session_id":"11111111-2222-3333-4444-555555555555","transcript_path":"/t.jsonl","cwd":"/r","model":{"id":"claude-opus-5","display_name":"Opus 5"},"context_window":{"total_input_tokens":84500,"total_output_tokens":120,"context_window_size":200000,"current_usage":{"input_tokens":4,"output_tokens":120,"cache_creation_input_tokens":1500,"cache_read_input_tokens":83000},"used_percentage":42.25,"remaining_percentage":57.75},"effort":{"level":"xhigh"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1790000000}}}"#
        let e = try HookEvent.decode(Data(json.utf8))
        let report = try #require(e.statusLine)
        #expect(report.contextUsedPercentage == 42.25)
        #expect(report.contextWindowSize == 200000)
        #expect(report.contextTokens == 84500)
        #expect(report.modelDisplayName == "Opus 5")
        #expect(report.effort == "xhigh")
        #expect(e.model == nil)
        #expect(SessionStateMachine.reduce(.working, event: e) == nil)
        // Round-trips through the trace encoder.
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let again = try HookEvent.decode(enc.encode(e))
        #expect(again.hookEventName == "StatusLine")

        let early = try HookEvent.decode(Data(#"{"hook_event_name":"StatusLine","session_id":"s","context_window":{"used_percentage":null}}"#.utf8))
        #expect(early.statusLine?.contextUsedPercentage == nil)
        let hook = try HookEvent.decode(Data(#"{"hook_event_name":"Stop","session_id":"s","context_window":{"used_percentage":5}}"#.utf8))
        #expect(hook.statusLine == nil)
    }
}
