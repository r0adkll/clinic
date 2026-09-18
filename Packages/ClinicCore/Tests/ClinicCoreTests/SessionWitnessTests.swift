import Foundation
import Testing
@testable import ClinicCore

/// ADR-166. The hook sequences are the ones the real CLI (2.1.276) sent a logging socket on 2026-09-18.
@Suite struct SessionWitnessTests {
    let id = SessionID("11111111-2222-3333-4444-555555555555")

    private func reduce(_ events: [HookEvent], from start: SessionState = .launching) -> [SessionState] {
        var state = start
        return events.map { e in if let next = SessionStateMachine.reduce(state, event: e) { state = next }; return state }
    }

    // MARK: Reducer

    @Test func clearIsNotAnExit() {
        let end = HookEvent(hookEventName: "SessionEnd", sessionId: id, reason: "clear")
        #expect(reduce([end], from: .idle) == [.idle])
        #expect(reduce([HookEvent(hookEventName: "SessionEnd", sessionId: id, reason: "prompt_input_exit")], from: .idle) == [.exited])
        #expect(reduce([HookEvent(hookEventName: "SessionEnd", sessionId: id)], from: .idle) == [.exited])
    }

    @Test func compactionInsideATurnDoesNotEndIt() {
        let compact = HookEvent(hookEventName: "SessionStart", sessionId: id, source: "compact")
        #expect(reduce([compact], from: .working) == [.working])
        #expect(reduce([compact], from: .idle) == [.idle])
        #expect(reduce([HookEvent(hookEventName: "SessionStart", sessionId: id, source: "clear")], from: .launching) == [.idle])
    }

    @Test func decodesReasonAndAgentId() throws {
        let e = try HookEvent.decode(Data(#"{"hook_event_name":"SessionEnd","session_id":"\#(id.rawValue)","reason":"clear","agent_id":"ae2066"}"#.utf8))
        #expect(e.reason == "clear")
        #expect(e.agentId == "ae2066")
    }

    // MARK: OSC 9;4

    @Test func quietReportEndsAnInterruptedTurnAfterItsGrace() {
        #expect(TerminalWitness.progress(busy: false, sawBusy: true, state: .working, waitingOn: nil) == .after(TerminalWitness.quietGrace, .idle))
        #expect(TerminalWitness.stillHolds(.idle, busy: false, state: .working, waitingOn: nil))
    }

    /// Esc at a permission dialog fires no hook at all; the report clears.
    @Test func quietReportEndsADismissedPermissionDialog() {
        #expect(TerminalWitness.progress(busy: false, sawBusy: true, state: .waitingForPermission, waitingOn: nil) == .after(TerminalWitness.quietGrace, .idle))
    }

    /// With the setting off the CLI sends one `remove` at startup and another at exit, and nothing between.
    @Test func quietReportFromATerminalThatNeverSaidBusyIsIgnored() {
        #expect(TerminalWitness.progress(busy: false, sawBusy: false, state: .working, waitingOn: nil) == .settle)
    }

    @Test func quietReportChangesNothingAtRest() {
        for state in [SessionState.idle, .waitingForInput, .launching, .exited] {
            #expect(TerminalWitness.progress(busy: false, sawBusy: true, state: state, waitingOn: nil) == .settle)
        }
    }

    @Test func aStopHookOrANewBusyReportOverrulesAPendingQuietVerdict() {
        #expect(!TerminalWitness.stillHolds(.idle, busy: false, state: .idle, waitingOn: nil))
        #expect(!TerminalWitness.stillHolds(.idle, busy: true, state: .working, waitingOn: nil))
    }

    @Test func busyReportStartsATurnWhoseHookWasLost() {
        #expect(TerminalWitness.progress(busy: true, sawBusy: true, state: .idle, waitingOn: nil) == .after(TerminalWitness.busyGrace, .working))
        #expect(TerminalWitness.progress(busy: true, sawBusy: true, state: .waitingForInput, waitingOn: "idle_prompt") == .after(TerminalWitness.busyGrace, .working))
        // A dialog is not the prompt: the report says nothing about who answers it.
        #expect(TerminalWitness.progress(busy: true, sawBusy: true, state: .waitingForInput, waitingOn: "elicitation_dialog") == .settle)
        #expect(TerminalWitness.progress(busy: true, sawBusy: true, state: .working, waitingOn: nil) == .settle)
    }

    /// `/exit` sets the report for a quarter of a second before clearing it.
    @Test func aBusyBlipShorterThanItsGraceStartsNothing() {
        #expect(TerminalWitness.busyGrace > 0.25)
        #expect(!TerminalWitness.stillHolds(.working, busy: false, state: .idle, waitingOn: nil))
        #expect(!TerminalWitness.stillHolds(.working, busy: true, state: .exited, waitingOn: nil))
    }

    // MARK: Title

    @Test func readsTheTitleGlyph() {
        #expect(TerminalWitness.titleActivity("✳ Claude Code") == .resting)
        #expect(TerminalWitness.titleActivity("◐ Numbers 1 to 400") == .moving)
        #expect(TerminalWitness.titleActivity("◑ Numbers 1 to 400") == .moving)
        #expect(TerminalWitness.titleActivity("⠋ Older spinner") == .moving)
        #expect(TerminalWitness.titleActivity("fish /Users/x") == nil)
        #expect(TerminalWitness.titleActivity("") == nil)
    }

    /// `PreToolUse` arrives before `PermissionRequest`, so nothing but the title says a permission was granted.
    @Test func aMovingTitleAnswersThePermissionDialog() {
        #expect(TerminalWitness.title("◐ Create note.txt file", state: .waitingForPermission) == .working)
        #expect(TerminalWitness.title("✳ Create note.txt file", state: .waitingForPermission) == nil)
        #expect(TerminalWitness.title("◐ Create note.txt file", state: .idle) == nil)
        #expect(TerminalWitness.title("◐ Create note.txt file", state: .working) == nil)
    }

    // MARK: Transcript

    @Test func transcriptEndsOnlyAStateThatBeganBeforeIt() {
        let began = Date(timeIntervalSince1970: 1_000)
        #expect(TerminalWitness.transcriptEndsTurn(lastTurnEnd: began.addingTimeInterval(12), state: .working, since: began))
        #expect(TerminalWitness.transcriptEndsTurn(lastTurnEnd: began.addingTimeInterval(12), state: .waitingForPermission, since: began))
        // The previous turn's closing record, written as a queued prompt was submitted.
        #expect(!TerminalWitness.transcriptEndsTurn(lastTurnEnd: began.addingTimeInterval(0.02), state: .working, since: began))
        #expect(!TerminalWitness.transcriptEndsTurn(lastTurnEnd: began.addingTimeInterval(-30), state: .working, since: began))
        #expect(!TerminalWitness.transcriptEndsTurn(lastTurnEnd: began.addingTimeInterval(12), state: .idle, since: began))
        #expect(!TerminalWitness.transcriptEndsTurn(lastTurnEnd: nil, state: .working, since: began))
    }

    @Test func activityRecordsInterruptsAndTurnDurations() {
        var a = SessionActivity()
        #expect(a.lastTurnEnd == nil)
        a.apply(line: Data(#"{"type":"user","isSidechain":false,"timestamp":"2026-09-18T10:00:05.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#.utf8))
        #expect(a.lastTurnEnd == TranscriptReader.parseDate("2026-09-18T10:00:05.000Z"))
        a.apply(line: Data(#"{"type":"user","timestamp":"2026-09-18T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#.utf8))
        #expect(a.lastTurnEnd == TranscriptReader.parseDate("2026-09-18T10:01:00.000Z"))
        a.apply(line: Data(#"{"type":"system","subtype":"turn_duration","durationMs":188163,"isSidechain":false,"timestamp":"2026-09-18T10:02:00.000Z"}"#.utf8))
        #expect(a.lastTurnEnd == TranscriptReader.parseDate("2026-09-18T10:02:00.000Z"))
        // A subagent's interrupt is not the session's.
        a.apply(line: Data(#"{"type":"user","isSidechain":true,"timestamp":"2026-09-18T10:03:00.000Z","message":{"role":"user","content":"[Request interrupted by user]"}}"#.utf8))
        #expect(a.lastTurnEnd == TranscriptReader.parseDate("2026-09-18T10:02:00.000Z"))
    }
}

/// ADR-167.
@Suite struct SocketClaimTests {
    private func tempDir() throws -> URL {
        // Short: a Unix socket path holds 103 bytes.
        let url = URL(fileURLWithPath: "/tmp/clinic-claim-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Clinic"), withIntermediateDirectories: true)
        return url
    }

    @Test func firstInstanceKeepsThePlainNamesAndTheSecondLeavesThemAlone() throws {
        let appSupport = try tempDir()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        #expect(SocketClaim.instanceSuffix(appSupport: appSupport, pid: 4242) == "")

        let first = HookServer(socketPath: HookServer.defaultSocketPath(appSupport: appSupport))
        try first.start()
        defer { first.stop() }
        #expect(SocketClaim.instanceSuffix(appSupport: appSupport, pid: 4242) == "-4242")

        let second = HookServer(socketPath: HookServer.defaultSocketPath(appSupport: appSupport, suffix: "-4242"))
        try second.start()
        #expect(second.socketPath.hasSuffix("/Clinic/hook-4242.sock"))
        second.stop()
        // The second one coming and going took nothing from the first.
        #expect(SocketClaim.isLive(first.socketPath))
        #expect(!FileManager.default.fileExists(atPath: second.socketPath))
    }

    @Test func aDeadListenersSocketFileIsNotAClaim() throws {
        let appSupport = try tempDir()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        FileManager.default.createFile(atPath: HookServer.defaultSocketPath(appSupport: appSupport), contents: nil)
        #expect(SocketClaim.instanceSuffix(appSupport: appSupport, pid: 1) == "")
    }

    @Test func stoppingLeavesASocketSomeoneElseBoundAtThePath() throws {
        let appSupport = try tempDir()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let path = HookServer.defaultSocketPath(appSupport: appSupport)
        let old = HookServer(socketPath: path, watchdogInterval: 60)
        try old.start()
        let thief = HookServer(socketPath: path, watchdogInterval: 60)   // what a build before ADR-167 does
        try thief.start()
        defer { thief.stop() }
        old.stop()
        #expect(SocketClaim.isLive(path))
    }

    @Test func aRemovedSocketIsBoundAgain() async throws {
        let appSupport = try tempDir()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let path = HookServer.defaultSocketPath(appSupport: appSupport)
        let server = HookServer(socketPath: path, watchdogInterval: 0.1)
        try server.start()
        defer { server.stop() }
        unlink(path)
        #expect(!SocketClaim.isLive(path))
        var live = false
        for _ in 0..<40 where !live { try await Task.sleep(for: .milliseconds(50)); live = SocketClaim.isLive(path) }
        #expect(live)

        let payload = Data(#"{"session_id":"11111111-2222-3333-4444-555555555555","hook_event_name":"Stop"}"#.utf8)
        #expect(HookClient.send(payload, to: path))
        let events = server.events
        let received = await withTimeout(seconds: 5) { () -> HookEvent? in
            for await e in events { return e }
            return nil
        }
        #expect(received??.hookEventName == "Stop")
    }

    @Test func readsThePidOutOfSuffixedNamesOnly() {
        #expect(SocketClaim.pid(inFileName: "hook-123.sock") == 123)
        #expect(SocketClaim.pid(inFileName: "mcp-77.sock") == 77)
        #expect(SocketClaim.pid(inFileName: "hooks-123.json") == 123)
        #expect(SocketClaim.pid(inFileName: "hooks-123-worktree-head.json") == 123)
        #expect(SocketClaim.pid(inFileName: "hook.sock") == nil)
        #expect(SocketClaim.pid(inFileName: "hooks.json") == nil)
        #expect(SocketClaim.pid(inFileName: "hooks-worktree-head.json") == nil)
        #expect(SocketClaim.pid(inFileName: "state.json") == nil)
    }

    @Test func sweepRemovesOnlyWhatDeadInstancesLeft() throws {
        let appSupport = try tempDir()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let dir = appSupport.appendingPathComponent("Clinic")
        for name in ["hook.sock", "hooks.json", "hooks-worktree-head.json", "hook-111.sock", "hooks-111.json", "hooks-111-worktree-fresh.json", "mcp-111.sock", "hook-222.sock"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
        }
        SocketClaim.sweepStale(in: dir, isAlive: { $0 == 222 })
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == ["hook.sock", "hooks.json", "hooks-worktree-head.json", "hook-222.sock"])
    }
}
