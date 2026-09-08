import Foundation
import Testing
@testable import ClinicCore

@Suite struct StateStoreTests {
    @Test func decodesOlderStateMissingNewFields() throws {
        let json = #"{"version":1,"favorites":["11111111-2222-3333-4444-555555555555"],"manualNames":{}}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let s = try d.decode(ClinicState.self, from: Data(json.utf8))
        #expect(s.favorites.count == 1)
        #expect(s.mutedSessions.isEmpty)
        #expect(s.archived.isEmpty)
    }

    @Test func decodesLegacyFlatArrayMaps() throws {
        let json = #"{"manualNames":["11111111-2222-3333-4444-555555555555","Named"],"archived":["22222222-2222-3333-4444-555555555555","2026-09-07T10:00:00Z"]}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let s = try d.decode(ClinicState.self, from: Data(json.utf8))
        #expect(s.manualNames[SessionID("11111111-2222-3333-4444-555555555555")] == "Named")
        #expect(s.archived[SessionID("22222222-2222-3333-4444-555555555555")] != nil)
    }

    @Test func sessionMapsEncodeAsObjects() throws {
        var s = ClinicState(); s.manualNames[SessionID("11111111-2222-3333-4444-555555555555")] = "x"
        let data = try JSONEncoder().encode(s)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["manualNames"] is [String: Any])
    }

    @Test func roundTrips() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-state-\(UUID().uuidString)/state.json")
        let store = StateStore(url: url, debounce: .milliseconds(10))
        let id = SessionID("11111111-2222-3333-4444-555555555555")
        await store.update { $0.favorites.insert(id); $0.manualNames[id] = "Named"; $0.archived[id] = Date(timeIntervalSince1970: 1_000_000) }
        await store.flush()
        let reloaded = StateStore(url: url)
        let s = await reloaded.state
        #expect(s.favorites.contains(id))
        #expect(s.manualNames[id] == "Named")
        #expect(s.archived[id] == Date(timeIntervalSince1970: 1_000_000))
    }
}
