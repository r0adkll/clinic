import Foundation

/// The ordered list of audio files a notification can sound with, and the rotation over them (ADR-097).
///
/// Foundation only: playback belongs to the app target, and everything decided here — order,
/// wraparound, skipping a file that has gone missing, and what to do when they all have — is
/// answerable without a speaker.
public struct NotificationSounds: Codable, Sendable, Hashable {
    public struct Sound: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        /// The file as the user picked it. Clinic references audio, it never copies it.
        public var path: String

        public init(id: UUID = UUID(), path: String) {
            self.id = id
            self.path = path
        }

        public var url: URL { URL(fileURLWithPath: path) }
        /// The file name without its extension: what the list shows.
        public var name: String { url.deletingPathExtension().lastPathComponent }
    }

    public var sounds: [Sound]

    public init(sounds: [Sound] = []) {
        self.sounds = sounds
    }

    public var isEmpty: Bool { sounds.isEmpty }

    public mutating func append(path: String) {
        sounds.append(Sound(path: path))
    }

    public mutating func remove(_ id: UUID) {
        sounds.removeAll { $0.id == id }
    }

    /// SwiftUI's `onMove` contract, spelled out here because `move(fromOffsets:toOffset:)` comes
    /// from SwiftUI and ClinicCore is Foundation-only.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moved = source.map { sounds[$0] }
        let kept = sounds.enumerated().filter { !source.contains($0.offset) }
        let insertAt = kept.firstIndex { $0.offset >= destination } ?? kept.count
        var result = kept.map(\.element)
        result.insert(contentsOf: moved, at: insertAt)
        sounds = result
    }

    /// What a notification should sound with, given where the rotation stands.
    public enum Choice: Sendable, Hashable {
        /// Play this file; the system notification is posted silent so the sound is not doubled.
        case file(URL)
        /// No usable file — let the system make the noise it always has.
        case systemDefault
    }

    /// The next sound in the rotation, advancing `cursor` past it.
    ///
    /// Entries whose file is unreadable are skipped rather than sounding silently. If every entry is
    /// missing the caller gets `.systemDefault`: a notification nobody hears cannot be told apart
    /// from a notification that never fired.
    public func next(cursor: inout Int, exists: (URL) -> Bool = { FileManager.default.isReadableFile(atPath: $0.path) }) -> Choice {
        guard !sounds.isEmpty else { return .systemDefault }
        if cursor < 0 || cursor >= sounds.count { cursor = 0 }
        for offset in 0..<sounds.count {
            let index = (cursor + offset) % sounds.count
            let url = sounds[index].url
            if exists(url) {
                cursor = (index + 1) % sounds.count
                return .file(url)
            }
        }
        cursor = 0
        return .systemDefault
    }

    // MARK: - Storage

    /// The `UserDefaults` key holding the JSON list. The master on/off stays `ClinicNotificationSound`.
    public static let defaultsKey = "ClinicNotificationSoundFiles"

    public init(json: Data?) {
        guard let json, let decoded = try? JSONDecoder().decode(NotificationSounds.self, from: json) else {
            self.init()
            return
        }
        self = decoded
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
