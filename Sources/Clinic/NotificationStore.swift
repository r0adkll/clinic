import Foundation
import Observation
import ClinicCore

/// In-app notification history (milestone 2). Entries are session-scoped; delivery to the system goes through NotificationService.
@MainActor
@Observable
final class NotificationStore {
    struct Entry: Identifiable, Hashable {
        enum Kind: Hashable { case finished, needsPermission, needsInput, error }
        let id = UUID()
        let date: Date
        let sessionId: SessionID
        let title: String
        let body: String
        let kind: Kind
        var read = false
    }

    private(set) var entries: [Entry] = []
    var unreadCount: Int { entries.filter { !$0.read }.count }
    static let maxEntries = 200

    @discardableResult
    func record(sessionId: SessionID, title: String, body: String, kind: Entry.Kind) -> Entry {
        let e = Entry(date: Date(), sessionId: sessionId, title: title, body: body, kind: kind)
        entries.insert(e, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        return e
    }

    func markAllRead() { for i in entries.indices { entries[i].read = true } }
    func markRead(sessionId: SessionID) { for i in entries.indices where entries[i].sessionId == sessionId { entries[i].read = true } }
    func clear() { entries.removeAll() }
}
