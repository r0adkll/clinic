import Foundation
import Testing
@testable import ClinicCore

@Suite struct HookServerTests {
    @Test func receivesPayloadFromClient() async throws {
        let path = "/tmp/clinic-test-\(UInt32.random(in: 0...UInt32.max)).sock"
        let server = HookServer(socketPath: path)
        try server.start()
        defer { server.stop() }

        let payload = Data("""
        {"session_id":"11111111-2222-3333-4444-555555555555","hook_event_name":"Stop","cwd":"/x","transcript_path":"/x/t.jsonl"}
        """.utf8)
        #expect(HookClient.send(payload, to: path))

        let events = server.events
        let received = await withTimeout(seconds: 5) { () -> HookEvent? in
            for await e in events { return e }
            return nil
        }
        #expect(received??.hookEventName == "Stop")
        #expect(received??.sessionId == SessionID("11111111-2222-3333-4444-555555555555"))
    }

    @Test func clientFailsGracefullyWithoutServer() {
        #expect(HookClient.send(Data("{}".utf8), to: "/tmp/does-not-exist-\(UUID().uuidString).sock") == false)
    }
}

func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await op() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
