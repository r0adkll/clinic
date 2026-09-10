import Foundation
import Testing
@testable import ClinicCore

/// Everything is present unless the test says otherwise; no file system is touched.
private func present(_ missing: Set<String> = []) -> (URL) -> Bool {
    { !missing.contains($0.lastPathComponent) }
}

private func sounds(_ names: String...) -> NotificationSounds {
    NotificationSounds(sounds: names.map { NotificationSounds.Sound(path: "/tmp/\($0)") })
}

@Test func emptyListFallsBackToTheSystemSound() {
    var set = NotificationSounds()
    var cursor = 0
    #expect(set.next(cursor: &cursor, exists: present()) == .systemDefault)
    set.append(path: "/tmp/a.wav")
    #expect(set.next(cursor: &cursor, exists: present()) == .file(URL(fileURLWithPath: "/tmp/a.wav")))
}

@Test func rotationWrapsInListOrder() {
    let set = sounds("a.wav", "b.wav", "c.wav")
    var cursor = 0
    var heard: [String] = []
    for _ in 0..<7 {
        if case .file(let url) = set.next(cursor: &cursor, exists: present()) { heard.append(url.lastPathComponent) }
    }
    #expect(heard == ["a.wav", "b.wav", "c.wav", "a.wav", "b.wav", "c.wav", "a.wav"])
}

@Test func aSingleSoundRepeats() {
    let set = sounds("only.wav")
    var cursor = 0
    #expect(set.next(cursor: &cursor, exists: present()) == .file(URL(fileURLWithPath: "/tmp/only.wav")))
    #expect(set.next(cursor: &cursor, exists: present()) == .file(URL(fileURLWithPath: "/tmp/only.wav")))
}

@Test func missingFilesAreSkippedNotSounded() {
    let set = sounds("a.wav", "gone.wav", "c.wav")
    var cursor = 0
    var heard: [String] = []
    for _ in 0..<4 {
        if case .file(let url) = set.next(cursor: &cursor, exists: present(["gone.wav"])) { heard.append(url.lastPathComponent) }
    }
    #expect(heard == ["a.wav", "c.wav", "a.wav", "c.wav"])
}

@Test func everyFileMissingFallsBackRatherThanGoingQuiet() {
    let set = sounds("a.wav", "b.wav")
    var cursor = 1
    #expect(set.next(cursor: &cursor, exists: present(["a.wav", "b.wav"])) == .systemDefault)
    #expect(cursor == 0)
}

@Test func aCursorLeftPastTheEndStartsOver() {
    let set = sounds("a.wav", "b.wav")
    var cursor = 9
    #expect(set.next(cursor: &cursor, exists: present()) == .file(URL(fileURLWithPath: "/tmp/a.wav")))
    #expect(cursor == 1)
}

@Test func removingAndReorderingChangeTheRotation() {
    var set = sounds("a.wav", "b.wav", "c.wav")
    set.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    #expect(set.sounds.map(\.name) == ["c", "a", "b"])
    set.remove(set.sounds[1].id)
    #expect(set.sounds.map(\.name) == ["c", "b"])
}

@Test func theListSurvivesARoundTripThroughDefaults() {
    let set = sounds("ding.aiff", "chime.m4a")
    let restored = NotificationSounds(json: set.encoded())
    #expect(restored == set)
    #expect(restored.sounds.first?.name == "ding")
}

@Test func absentOrCorruptStorageDecodesToAnEmptyList() {
    #expect(NotificationSounds(json: nil).isEmpty)
    #expect(NotificationSounds(json: Data("not json".utf8)).isEmpty)
}
