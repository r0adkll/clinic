import Foundation
import Testing
@testable import ClinicCore

// MARK: - Limits

@Test func contextSoundsOnceOnTheWayUpAndRearmsAfterCompaction() {
    var watch = ResourceWatch()
    let steps: [(Double?, String)] = [(nil, "a"), (85, "a"), (91, "a"), (95, "a"), (90, "b"), (85, "a"), (92, "a"), (30, "a"), (90, "a")]
    var heard: [Bool] = []
    for (percentage, session) in steps { heard.append(watch.context(percentage, session: session)) }
    // Once on the way up, once for another session, nothing between the lines, again after compaction.
    #expect(heard == [false, false, true, false, true, false, false, false, true])
}

@Test func thePlanWindowSoundsOncePerWindow() {
    var watch = ResourceWatch()
    let first = Date(timeIntervalSince1970: 1_000), second = Date(timeIntervalSince1970: 19_000)
    let windows: [StatusLineReport.RateWindow?] = [
        .init(usedPercentage: 80, resetsAt: first), .init(usedPercentage: 90, resetsAt: first), .init(usedPercentage: 99, resetsAt: first),
        .init(usedPercentage: 10, resetsAt: second), .init(usedPercentage: 93, resetsAt: second), nil,
    ]
    var heard: [Bool] = []
    for window in windows { heard.append(watch.plan(window)) }
    #expect(heard == [false, true, false, false, true, false])
}

@Test func aLimitIsToldApartFromAnError() {
    #expect(ResourceWatch.isLimit("API Error: 429 rate_limit_error"))
    #expect(ResourceWatch.isLimit("You've hit your usage limit"))
    #expect(!ResourceWatch.isLimit("API Error: 500 Internal server error"))
    #expect(!ResourceWatch.isLimit(nil))
}

@Test func longTurnsAreOptInAndStayOffForOldSettings() throws {
    var settings = SoundSettings()
    let before = (settings.isOn(.turnLong), settings.isOn(.contextFilling))
    settings.set(.turnLong, on: true)
    settings.set(.contextFilling, on: false)
    let after = (settings.isOn(.turnLong), settings.isOn(.contextFilling))
    #expect(before == (false, true))
    #expect(after == (true, false))
    // Settings saved before the opt-in existed carry an empty disabled list, and must not turn it on.
    let old = SoundSettings(json: Data(#"{"enabled":true,"volume":0.5,"disabledWitnesses":[]}"#.utf8))
    #expect(!old.isOn(.turnLong))
    #expect(SoundSettings(json: settings.encoded()) == settings)
    #expect(SoundWitness.rateLimited.category == .resourceLimit && SoundWitness.turnLong.category == .taskProgress)
}

// MARK: - peon-ping

@Test func peonPingIsFoundByItsHookCommands() {
    let with = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/Users/me/.claude/hooks/peon-ping/peon.sh"}]}]}}"#.utf8)
    let without = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]},"model":"opus"}"#.utf8)
    #expect(PeonPing.hooksInstalled(settingsJSON: with))
    #expect(!PeonPing.hooksInstalled(settingsJSON: without))
    #expect(!PeonPing.hooksInstalled(settingsJSON: Data("not json".utf8)))
}

@Test func importingPeonPingMapsItsSettingsOntoClinics() throws {
    let config = try PeonPing.Config(json: Data("""
    {
      "volume": 1.4, "active_pack": "peon",
      "categories": {"task.error": false, "user.spam": true, "made.up": false},
      "path_rules": [
        {"pattern": "*/work/*", "pack": "glados"},
        {"pattern": "~/SoftwareProjects/clinic", "pack": "kerrigan"},
        {"pattern": "*/elsewhere/*", "pack": "peon"},
        {"pattern": "*/work/api", "pack": "peon"}
      ],
      "pack_rotation": ["peon", "zug"], "pack_rotation_mode": "random"
    }
    """.utf8))
    let plan = PeonPing.plan(config, projects: ["/Users/me/work/api", "/Users/me/SoftwareProjects/clinic", "/Users/me/other"],
                             installed: ["peon", "glados"], home: "/Users/me")
    #expect(plan.defaultPack == "peon")
    #expect(plan.volume == 1)
    #expect(plan.disabledCategories == [.taskError])
    #expect(plan.rotation == ["peon"])
    // The first rule to match wins; a rule whose pack is not installed sets nothing.
    #expect(plan.projectPacks == ["/Users/me/work/api": "glados"])
    #expect(plan.missingPacks == ["zug", "kerrigan"])
    #expect(plan.unmatchedRules == ["*/elsewhere/*"])

    let overriding = try PeonPing.Config(json: Data(#"{"pack_rotation":["peon"],"pack_rotation_mode":"session_override"}"#.utf8))
    #expect(PeonPing.plan(overriding, projects: [], installed: ["peon"]).rotation.isEmpty)
}

@Test func theQuietFolderIsWhatPeonPingNeeds() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peon-quiet-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try PeonPing.prepareQuietDirectory(dir)
    try PeonPing.prepareQuietDirectory(dir)   // idempotent
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("packs").path, isDirectory: &isDirectory) && isDirectory.boolValue)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".paused").path))
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("config.json"))) as? [String: Bool]
    #expect(config?["enabled"] == false)
}
