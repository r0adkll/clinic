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
}
