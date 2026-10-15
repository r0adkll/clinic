import Foundation
import Testing
@testable import ClinicCore

// ADR-208: the toolbar pauses pack lines for a while.

@Test func aPauseSilencesPackLinesUntilItEnds() {
    let manifest = CESPManifest(name: "test", displayName: "Test", categories: [
        CESPCategory.taskComplete.rawValue: .init(sounds: [.init(file: "sounds/a.wav", label: "a")]),
    ])
    let t = Date(timeIntervalSince1970: 10_000)
    var settings = SoundSettings()
    settings.pausedUntil = t.addingTimeInterval(60)
    var router = SoundRouter()
    #expect(settings.isPaused(at: t))
    #expect(!settings.speaks(at: t))
    #expect(router.decide(.turnFinished, session: "s", manifest: manifest, settings: settings, now: t) == .pass)
    #expect(!settings.isPaused(at: t.addingTimeInterval(60)))
    if case .play = router.decide(.turnFinished, session: "s", manifest: manifest, settings: settings, now: t.addingTimeInterval(61)) {} else {
        Issue.record("a pause that has ended should not hold the line")
    }
}

@Test func aPauseSurvivesTheRoundTripAndOldSettingsHaveNone() throws {
    var settings = SoundSettings()
    #expect(settings.pausedUntil == nil)
    settings.pausedUntil = Date(timeIntervalSince1970: 1_234_567)
    #expect(SoundSettings(json: settings.encoded()).pausedUntil == settings.pausedUntil)
    let old = SoundSettings(json: Data(#"{"enabled": true, "volume": 0.4}"#.utf8))
    #expect(old.pausedUntil == nil && old.speaks())
}

@Test func morningIsTheNextEightOClock() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)))
    }
    #expect(SoundPause.untilMorning.end(from: try at(15, 22, 30), calendar: calendar) == (try at(16, 8)))
    #expect(SoundPause.untilMorning.end(from: try at(15, 2), calendar: calendar) == (try at(15, 8)))
    #expect(SoundPause.untilMorning.end(from: try at(15, 8), calendar: calendar) == (try at(16, 8)))
    #expect(SoundPause.oneHour.end(from: try at(15, 9), calendar: calendar) == (try at(15, 10)))
}
