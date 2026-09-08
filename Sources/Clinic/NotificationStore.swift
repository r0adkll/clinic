import Foundation
import Observation
import ClinicCore

/// In-app notification history (milestone 2). Entries are session-scoped; delivery to the system goes through NotificationService.
@MainActor
@Observable
final class NotificationStore {
    struct Entry: Identifiable, Hashable {
        enum Kind: Hashable { case finished, needsPermission, needsInput, error, bell, update }
        let id = UUID()
        let date: Date
        let sessionId: SessionID?
        let title: String
        let body: String
        let kind: Kind
        var url: URL? = nil
        var read = false
    }

    /// The card currently sliding in over the window (ADR-066), if any.
    var card: Entry?
    private var cardTask: Task<Void, Never>?

    func showCard(_ e: Entry) {
        card = e
        cardTask?.cancel()
        cardTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            if self?.card?.id == e.id { self?.card = nil }
        }
    }

    func dismissCard() { cardTask?.cancel(); card = nil }

    func remove(_ id: UUID) { entries.removeAll { $0.id == id } }
    func markRead(_ id: UUID) { if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].read = true } }

    private(set) var entries: [Entry] = []
    var unreadCount: Int { entries.filter { !$0.read }.count }
    static let maxEntries = 200

    /// Bells from the same session within 5 s collapse into one row.
    @discardableResult
    func record(sessionId: SessionID?, title: String, body: String, kind: Entry.Kind, url: URL? = nil) -> Entry {
        if kind == .bell, let last = entries.first, last.kind == .bell, last.sessionId == sessionId, Date().timeIntervalSince(last.date) < 5 { return last }
        let e = Entry(date: Date(), sessionId: sessionId, title: title, body: body, kind: kind, url: url)
        entries.insert(e, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        return e
    }

    func markAllRead() { for i in entries.indices { entries[i].read = true } }
    func markRead(sessionId: SessionID) { for i in entries.indices where entries[i].sessionId == sessionId { entries[i].read = true } }
    func clear() { entries.removeAll() }
}
