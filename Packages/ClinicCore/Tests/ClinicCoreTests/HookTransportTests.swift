import Foundation
import Darwin
import Testing
@testable import ClinicCore

/// ADR-177: hooks arrive through Clinic's session mod, over HTTP on the hook socket.
@Suite struct HookTransportTests {
    static let document = #"{"session_id":"11111111-2222-3333-4444-555555555555","hook_event_name":"Stop","_clinic_via":"mod"}"#

    static func request(body: String, contentLength: Int? = nil) -> Data {
        Data("POST /hook HTTP/1.1\r\nContent-Type: application/json\r\nHost: clinic\r\ncontent-length: \(contentLength ?? body.utf8.count)\r\n\r\n\(body)".utf8)
    }

    // MARK: Framing

    @Test func bareDocumentIsRaw() {
        let data = Data(Self.document.utf8)
        #expect(HookWire.read(data) == .raw(data))
    }

    @Test func wholeRequestYieldsItsBody() {
        #expect(HookWire.read(Self.request(body: Self.document)) == .http(.init(method: "POST", target: "/hook", body: Data(Self.document.utf8))))
    }

    @Test func requestIsIncompleteUntilTheBodyArrives() {
        let whole = Self.request(body: Self.document)
        #expect(HookWire.read(whole.prefix(3)) == .incomplete)
        #expect(HookWire.read(whole.prefix(40)) == .incomplete)
        #expect(HookWire.read(whole.dropLast(1)) == .incomplete)
        #expect(HookWire.read(Self.request(body: "{}", contentLength: 10)) == .incomplete)
    }

    @Test func bodyStopsAtItsAnnouncedLength() {
        #expect(HookWire.read(Self.request(body: "{}trailing", contentLength: 2)) == .http(.init(method: "POST", target: "/hook", body: Data("{}".utf8))))
    }

    @Test func serverAnswersAPostAndDeliversItsBody() async throws {
        let path = "/tmp/clinic-test-\(UInt32.random(in: 0...UInt32.max)).sock"
        let server = HookServer(socketPath: path)
        try server.start()
        defer { server.stop() }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(connected == 0)
        // No shutdown: an HTTP client keeps its side open and waits for the answer.
        let request = Self.request(body: Self.document)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count)
        #expect(String(decoding: buffer.prefix(max(n, 0)), as: UTF8.self).hasPrefix("HTTP/1.1 204"))

        let events = server.events
        let received = await withTimeout(seconds: 5) { () -> HookEvent? in
            for await e in events { return e }
            return nil
        }
        #expect(received??.hookEventName == "Stop")
        #expect(received??.via == "mod")
    }

    // MARK: Settings and launch

    @Test func modSettingsKeepOneProbeAndNoStatusLine() throws {
        let data = try HookSettings.json(helperPath: "/Applications/Clinic.app/Contents/MacOS/clinic-hook",
                                         socketPath: "/Users/me/Library/Application Support/Clinic/hook.sock",
                                         worktreeBaseRef: "head", transport: .mod)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Array(hooks.keys) == ["SessionStart"])
        let probe = try #require((hooks["SessionStart"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect((probe.first?["command"] as? String)?.hasSuffix("clinic-hook probe '/Users/me/Library/Application Support/Clinic/hook.sock'") == true)
        #expect(root["statusLine"] == nil)
        let options = ((root["pluginConfigs"] as? [String: Any])?[HookSettings.modName] as? [String: Any])?["options"] as? [String: Any]
        #expect(options?["socket"] as? String == "/Users/me/Library/Application Support/Clinic/hook.sock")
        #expect(root["terminalProgressBarEnabled"] as? Bool == true)
        #expect((root["worktree"] as? [String: Any])?["baseRef"] as? String == "head")
    }

    @Test func commandSettingsAreUnchanged() throws {
        let data = try HookSettings.json(helperPath: "/h", socketPath: "/s")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set((root["hooks"] as? [String: Any] ?? [:]).keys) == Set(HookSettings.events))
        #expect(root["statusLine"] != nil)
        #expect(root["pluginConfigs"] == nil)
        #expect(root["terminalProgressBarEnabled"] as? Bool == true)
    }

    @Test func launchNamesThePluginDirectory() {
        let id = SessionID("11111111-2222-3333-4444-555555555555")
        var launch = ClaudeLaunch(mode: .new(id: id), settingsFilePath: "/s/hooks-mod.json", pluginDirectory: "/s/Clinic Dev/mod.plugin", prompt: "hi")
        launch.mcpConfigPath = "/s/mcp.json"
        #expect(launch.arguments == ["hi", "--session-id", id.rawValue, "--settings", "/s/hooks-mod.json",
                                     "--plugin-dir", "/s/Clinic Dev/mod.plugin", "--mcp-config", "/s/mcp.json"])
        #expect(launch.shellLine.contains("--plugin-dir '/s/Clinic Dev/mod.plugin'"))
        #expect(!ClaudeLaunch(mode: .new(id: id), settingsFilePath: "/s/hooks.json").arguments.contains("--plugin-dir"))
    }

    // MARK: Choosing the transport

    @Test func parsesTheCLIVersion() {
        #expect(HookTransport.parseCLIVersion("2.1.287 (Claude Code)\n") == "2.1.287")
        #expect(HookTransport.parseCLIVersion("command not found") == nil)
        #expect(HookTransport.parseCLIVersion("") == nil)
    }

    @Test func automaticTransportFollowsTheCLI() {
        #expect(HookTransport.resolve(preference: nil, cliVersion: "2.1.287", failedOnVersion: nil) == .mod)
        #expect(HookTransport.resolve(preference: nil, cliVersion: "2.2.0", failedOnVersion: nil) == .mod)
        #expect(HookTransport.resolve(preference: nil, cliVersion: "2.1.286", failedOnVersion: nil) == .command)
        #expect(HookTransport.resolve(preference: nil, cliVersion: nil, failedOnVersion: nil) == .command)
        #expect(HookTransport.resolve(preference: "auto", cliVersion: "2.1.290", failedOnVersion: nil) == .mod)
    }

    @Test func aFailedLoadHoldsUntilTheCLIChanges() {
        #expect(HookTransport.resolve(preference: nil, cliVersion: "2.1.287", failedOnVersion: "2.1.287") == .command)
        #expect(HookTransport.resolve(preference: nil, cliVersion: "2.1.288", failedOnVersion: "2.1.287") == .mod)
    }

    @Test func aPreferenceForcesTheTransport() {
        #expect(HookTransport.resolve(preference: "command", cliVersion: "2.1.287", failedOnVersion: nil) == .command)
        #expect(HookTransport.resolve(preference: "mod", cliVersion: "2.1.287", failedOnVersion: "2.1.287") == .mod)
    }

    // MARK: What the mod sends

    @Test func anInterruptEndsTheTurn() {
        let id = SessionID("11111111-2222-3333-4444-555555555555")
        func turnEnd(_ reason: String, agent: String? = nil) -> HookEvent {
            HookEvent(hookEventName: HookEvent.turnEnd, sessionId: id, reason: reason, agentId: agent)
        }
        #expect(SessionStateMachine.reduce(.working, event: turnEnd("aborted")) == .idle)
        #expect(SessionStateMachine.reduce(.waitingForPermission, event: turnEnd("aborted")) == .idle)
        #expect(SessionStateMachine.reduce(.working, event: turnEnd("refusal")) == .idle)
        // `Stop` precedes an answered turn's end and has already moved it; one still moving here had none
        // (a permission prompt answered No, ADR-180). `StopFailure` speaks for an error, with the message.
        #expect(SessionStateMachine.reduce(.working, event: turnEnd("answer")) == .idle)
        #expect(SessionStateMachine.reduce(.waitingForPermission, event: turnEnd("answer")) == .idle)
        #expect(SessionStateMachine.reduce(.working, event: turnEnd("error")) == nil)
        #expect(SessionStateMachine.reduce(.working, event: turnEnd("error")) == nil)
        // A subagent's turn is not the session's, and a session at rest stays there.
        #expect(SessionStateMachine.reduce(.working, event: turnEnd("aborted", agent: "a1")) == nil)
        #expect(SessionStateMachine.reduce(.idle, event: turnEnd("aborted")) == nil)
    }

    @Test func theModsStatusReportDecodesLikeTheStatusLines() throws {
        let json = """
        {"hook_event_name":"StatusLine","session_id":"11111111-2222-3333-4444-555555555555","_clinic_via":"mod",
         "context_window":{"used_percentage":12,"context_window_size":200000,"total_input_tokens":24086},
         "model":{"id":"claude-haiku-4-5-20251001"},"effort":{"level":"high"},
         "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1790960000},"seven_day":{"used_percentage":7,"resets_at":1791400000}}}
        """
        let event = try HookEvent.decode(Data(json.utf8))
        let report = try #require(event.statusLine)
        #expect(event.via == "mod")
        #expect(report.contextUsedPercentage == 12)
        #expect(report.contextWindowSize == 200_000)
        #expect(report.contextTokens == 24_086)
        #expect(report.modelId == "claude-haiku-4-5-20251001")
        #expect(report.modelDisplayName == nil)
        #expect(report.effort == "high")
        #expect(report.fiveHour?.usedPercentage == 23.5)
        #expect(report.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_791_400_000))
    }

    @Test func aModFolderOfADeadInstanceIsSwept() {
        #expect(SocketClaim.pid(inFileName: "mod-123.plugin") == 123)
        #expect(SocketClaim.pid(inFileName: "hooks-123-mod.json") == 123)
        #expect(SocketClaim.pid(inFileName: "mod.plugin") == nil)
        #expect(SocketClaim.pid(inFileName: "hooks-mod.json") == nil)
    }
}

@Suite struct ModelSwitchEventTests {
    @Test func theSwitchNamesTheModelTheSessionRunsNow() throws {
        let json = #"{"hook_event_name":"PostModelSwitch","session_id":"11111111-2222-3333-4444-555555555555","from_model":"claude-haiku-4-5-20251001","to_model":"claude-sonnet-5-5","requested_model":"sonnet","source":"command"}"#
        #expect(try HookEvent.decode(Data(json.utf8)).model == "claude-sonnet-5-5")
        // The field this decoder used to read, so an old trace replays the same way.
        let legacy = #"{"hook_event_name":"PostModelSwitch","session_id":"11111111-2222-3333-4444-555555555555","new_model":"claude-opus-5-5"}"#
        #expect(try HookEvent.decode(Data(legacy.utf8)).model == "claude-opus-5-5")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601   // as the trace writes it
        let encoded = try encoder.encode(try HookEvent.decode(Data(json.utf8)))
        #expect(try HookEvent.decode(encoded).model == "claude-sonnet-5-5")
    }
}
