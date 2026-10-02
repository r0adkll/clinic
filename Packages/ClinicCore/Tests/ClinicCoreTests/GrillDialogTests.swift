import Foundation
import Darwin
import Testing
@testable import ClinicCore

/// ADR-179: Claude Code's own question dialog, answered in the Grill pane.
@Suite struct GrillDialogTests {
    static let asked = [
        AskedQuestion(question: "Which library should we use?", header: "Library", description: "For date formatting.",
                      options: [.init(label: "date-fns (Recommended)", description: "Small and tree-shakeable"),
                                .init(label: "Luxon", description: "Immutable, bigger")]),
        AskedQuestion(question: "Which targets?", header: "Targets",
                      options: [.init(label: "iOS"), .init(label: "macOS"), .init(label: "watchOS")], multiSelect: true),
        AskedQuestion(question: "What should it be called?", header: "Name", kind: "text"),
    ]

    @Test func aDialogBecomesARound() throws {
        let round = try #require(GrillRound.from(asked: Self.asked, toolUseId: "toolu_1"))
        #expect(round.source == .dialog)
        #expect(round.toolUseId == "toolu_1")
        #expect(round.isOpen)
        #expect(round.questions.map(\.id) == ["Q1", "Q2", "Q3"])
        let first = round.questions[0]
        #expect(first.title == "Which library should we use?")
        #expect(first.body == "For date formatting.")
        #expect(first.recommendation == "date-fns")
        #expect(first.recommendedChoice?.label == "date-fns (Recommended)")
        #expect(first.choices.map(\.detail) == ["Small and tree-shakeable", "Immutable, bigger"])
        #expect(round.questions[1].allowsMultiple)
        #expect(round.questions[1].recommendation == nil)
        #expect(round.questions[2].choices.isEmpty)
    }

    @Test func aDialogWithNoQuestionTextIsNoRound() {
        #expect(GrillRound.from(asked: [AskedQuestion(question: "  ")], toolUseId: "t") == nil)
        #expect(GrillRound.from(asked: [], toolUseId: "t") == nil)
    }

    @Test func answersAreKeyedByTheQuestionAndSpelledAsTheDialogWould() throws {
        var round = try #require(GrillRound.from(asked: Self.asked, toolUseId: "toolu_1"))
        round.answers = ["Q1": .acceptedRecommendation, "Q2": .choices(["3", "1"]), "Q3": .text("  Almanac \n")]
        #expect(round.dialogAnswers == [
            "Which library should we use?": "date-fns (Recommended)",
            "Which targets?": "watchOS, iOS",
            "What should it be called?": "Almanac",
        ])
    }

    @Test func aQuestionPassedOverSaysSo() throws {
        var round = try #require(GrillRound.from(asked: Self.asked, toolUseId: "toolu_1"))
        round.answers = ["Q1": .skipped, "Q2": .choices([])]
        #expect(Set(round.dialogAnswers.values) == [GrillRound.dialogSkipped])
        #expect(round.dialogAnswers.count == 3)
    }

    @Test func aTerminalAnswerIsRecorded() throws {
        var round = try #require(GrillRound.from(asked: Self.asked, toolUseId: "toolu_1"))
        round.record(dialogAnswers: ["Which library should we use?": "Luxon", "What should it be called?": "Almanac"])
        #expect(round.answers["Q1"] == .choices(["2"]))
        #expect(round.answers["Q2"] == nil)
        #expect(round.answers["Q3"] == .text("Almanac"))
    }

    @Test func aRoundKeepsItsToolCallAcrossTheStateFile() throws {
        let round = try #require(GrillRound.from(asked: Self.asked, toolUseId: "toolu_1"))
        let copy = try JSONDecoder().decode(GrillRound.self, from: JSONEncoder().encode(round))
        #expect(copy.toolUseId == "toolu_1")
        #expect(copy.source == .dialog)
        // A round from before this field, or from `ask_round`, has none.
        #expect(GrillRound(questions: round.questions).toolUseId == nil)
    }

    @Test func theModsEventsDecode() throws {
        let asked = """
        {"hook_event_name":"AskQuestion","session_id":"11111111-2222-3333-4444-555555555555","_clinic_via":"mod","tool_use_id":"toolu_9",
         "questions":[{"question":"Which fruit?","header":"Fruit","multiSelect":false,"options":[{"label":"Apple","description":"Crisp"},{"label":"Banana"}]}]}
        """
        let event = try HookEvent.decode(Data(asked.utf8))
        #expect(event.toolUseId == "toolu_9")
        #expect(event.questions?.first?.options.map(\.label) == ["Apple", "Banana"])
        let resolved = try HookEvent.decode(Data(#"{"hook_event_name":"AskResolved","session_id":"11111111-2222-3333-4444-555555555555","tool_use_id":"toolu_9","answers":{"Which fruit?":"Apple"}}"#.utf8))
        #expect(resolved.answers == ["Which fruit?": "Apple"])
        // Other events carry keys of these names in other shapes; they must still decode.
        let post = try HookEvent.decode(Data(#"{"hook_event_name":"Stop","session_id":"11111111-2222-3333-4444-555555555555","tool_use_id":7,"answers":"x","questions":3}"#.utf8))
        #expect(post.toolUseId == nil && post.answers == nil && post.questions == nil)
    }

    // MARK: The wire

    @Test func aGetIsARequestWithAQuery() {
        let data = Data("GET /answer?id=toolu_01AbC&x=a%20b HTTP/1.1\r\nHost: clinic\r\n\r\n".utf8)
        guard case .http(let request) = HookWire.read(data) else { Issue.record("not a request"); return }
        #expect(request.method == "GET")
        #expect(request.path == "/answer")
        #expect(request.query == ["id": "toolu_01AbC", "x": "a b"])
        #expect(HookWire.read(data.prefix(2)) == .incomplete)
    }

    /// Connects, sends a GET and returns the whole response once the server closes.
    static func get(_ target: String, socket path: String) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0 else { return "connect failed" }
        let request = Data("GET \(target) HTTP/1.1\r\nHost: clinic\r\n\r\n".utf8)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            out.append(buffer, count: n)
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func server(hold: TimeInterval = 20) throws -> (HookServer, AskBroker) {
        let server = HookServer(socketPath: "/tmp/clinic-test-\(UInt32.random(in: 0...UInt32.max)).sock")
        let broker = AskBroker()
        server.pollHold = hold
        server.onPoll = { target, poll in
            let request = HookWire.Request(method: "GET", target: target)
            guard request.path == "/answer", let id = request.query["id"] else { poll.respond(status: 404); return }
            broker.poll(id: id, poll)
        }
        try server.start()
        return (server, broker)
    }

    @Test func aWaitingPollGetsTheAnswerWhenItComes() async throws {
        let (server, broker) = try Self.server()
        defer { server.stop() }
        let path = server.socketPath
        async let response = Task.detached { Self.get("/answer?id=toolu_1", socket: path) }.value
        try await Task.sleep(for: .milliseconds(200))
        broker.answer(id: "toolu_1", with: ["Which fruit?": "Apple"])
        let text = await response
        #expect(text.hasPrefix("HTTP/1.1 200"))
        #expect(text.contains(#"{"answers":{"Which fruit?":"Apple"}}"#))
        // Delivered once: the dialog is over, and a later poll is told so.
        #expect(Self.get("/answer?id=toolu_1", socket: path).hasPrefix("HTTP/1.1 410"))
    }

    @Test func anAnswerGivenBetweenPollsIsKeptForTheNext() async throws {
        let (server, broker) = try Self.server()
        defer { server.stop() }
        broker.answer(id: "toolu_2", with: ["Q": "A"])
        #expect(broker.hasUndelivered(id: "toolu_2"))
        #expect(Self.get("/answer?id=toolu_2", socket: server.socketPath).hasPrefix("HTTP/1.1 200"))
        #expect(!broker.hasUndelivered(id: "toolu_2"))
    }

    @Test func aPollIsLetGoWithNothingWhenTheHoldRunsOut() async throws {
        let (server, _) = try Self.server(hold: 0.3)
        defer { server.stop() }
        #expect(Self.get("/answer?id=toolu_3", socket: server.socketPath).hasPrefix("HTTP/1.1 204"))
    }

    @Test func aClosedDialogReleasesItsPoll() async throws {
        let (server, broker) = try Self.server()
        defer { server.stop() }
        let path = server.socketPath
        async let response = Task.detached { Self.get("/answer?id=toolu_4", socket: path) }.value
        try await Task.sleep(for: .milliseconds(200))
        broker.close(id: "toolu_4")
        #expect(await response.hasPrefix("HTTP/1.1 410"))
        // And an answer that arrives after is dropped, not delivered to a dialog that is gone.
        broker.answer(id: "toolu_4", with: ["Q": "A"])
        #expect(!broker.hasUndelivered(id: "toolu_4"))
    }

    @Test func anUnknownPathIsNotFound() async throws {
        let (server, _) = try Self.server()
        defer { server.stop() }
        #expect(Self.get("/nothing", socket: server.socketPath).hasPrefix("HTTP/1.1 404"))
    }
}
