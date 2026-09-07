import Foundation
import Testing
@testable import ClinicCore

@Suite struct StateStoreTests {
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
