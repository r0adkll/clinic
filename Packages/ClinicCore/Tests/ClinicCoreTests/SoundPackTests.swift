import Foundation
import Testing
@testable import ClinicCore

// MARK: - Manifest

private let gladosJSON = """
{
  "cesp_version": "1.0", "name": "glados", "display_name": "GLaDOS (Portal)", "version": "1.0.0",
  "categories": {
    "session.start": { "sounds": [ { "file": "sounds/Hello.mp3", "label": "Hello" }, { "file": "Hi.mp3", "label": "Hi" } ] },
    "complete": { "sounds": [ { "file": "sounds/GoodNews.mp3", "label": "Good news." }, { "label": "no file" } ] },
    "task.error": { "sounds": [] }
  },
  "category_aliases": { "complete": "task.complete", "error": "task.error" }
}
"""

@Test func manifestResolvesAliasesAndBareFileNames() throws {
    let manifest = try JSONDecoder().decode(CESPManifest.self, from: Data(gladosJSON.utf8))
    #expect(manifest.lines(for: .sessionStart).map(\.path) == ["sounds/Hello.mp3", "sounds/Hi.mp3"])
    // `complete` is a legacy name the pack maps onto task.complete; the entry with no file is dropped.
    #expect(manifest.lines(for: .taskComplete).map(\.label) == ["Good news."])
    // An empty list and a missing category are both silence.
    #expect(manifest.lines(for: .taskError).isEmpty)
    #expect(manifest.lines(for: .inputRequired).isEmpty)
    #expect(manifest.voicedCategories == [.sessionStart, .taskComplete])
}

@Test func namesAndPathsFollowTheSpec() {
    #expect(CESPManifest.isValidName("sc_kerrigan"))
    #expect(CESPManifest.isValidName("peon-2"))
    #expect(!CESPManifest.isValidName("-peon"))
    #expect(!CESPManifest.isValidName("Peon"))
    #expect(!CESPManifest.isValidName(""))
    #expect(CESPManifest.isSafeRelativePath("sounds/Job_Done.wav"))
    #expect(!CESPManifest.isSafeRelativePath("../escape.wav"))
    #expect(!CESPManifest.isSafeRelativePath("sounds/../../x.wav"))
    #expect(!CESPManifest.isSafeRelativePath("/etc/passwd"))
    #expect(!CESPManifest.isSafeRelativePath("sounds/with space.wav"))
    #expect(!CESPManifest.isSafeRelativePath("sounds//x.wav"))
}

// MARK: - Registry

private let registryJSON = """
{ "version": 1, "total_packs": 5, "packs": [
  { "name": "peon", "display_name": "Orc Peon", "version": "1.1.0", "description": "Work work.",
    "author": { "name": "PeonPing", "github": "PeonPing" }, "trust_tier": "official", "quality": "gold",
    "categories": ["session.start", "task.complete"], "language": "en", "license": "CC-BY-NC-4.0",
    "sound_count": 20, "total_size_bytes": 1000, "source_repo": "PeonPing/og-packs", "source_ref": "v1.1.0",
    "source_path": "peon", "manifest_sha256": "abc", "tags": ["gaming", "warcraft"],
    "preview_sounds": ["PeonReady1.wav", "sounds/PeonYes1.wav"] },
  { "name": "quotes", "display_name": "Quotes", "version": "1.0.0", "description": "",
    "author": { "name": "x" }, "categories": [], "source_repo": "someone/quotes", "source_ref": "v1.0.0",
    "source_path": ".", "preview_sounds": [ { "file": "sounds/a.mp3", "label": "A line" } ] },
  { "name": "bad", "display_name": "Flagged", "version": "1.0.0", "quality": "flagged",
    "source_repo": "a/b", "source_ref": "v1", "source_path": "." },
  { "name": "rooted", "display_name": "Rooted", "version": "1.0.0", "source_repo": "a/rooted", "source_ref": "v1", "source_path": "" },
  { "name": "escape", "display_name": "Escape", "version": "1.0.0", "source_repo": "a/b", "source_ref": "v1", "source_path": "../x" },
  { "display_name": "No name" }
] }
"""

@Test func registryDecodesBothPreviewShapesAndDropsWhatItCannotInstall() throws {
    let registry = try SoundRegistry(json: Data(registryJSON.utf8))
    #expect(registry.packs.map(\.name) == ["peon", "quotes", "rooted"])
    #expect(registry.packs[2].rawURL("openpeon.json").absoluteString == "https://raw.githubusercontent.com/a/rooted/v1/openpeon.json")
    let peon = registry.packs[0]
    #expect(peon.previews.map(\.path) == ["sounds/PeonReady1.wav", "sounds/PeonYes1.wav"])
    #expect(peon.tarballURL.absoluteString == "https://github.com/PeonPing/og-packs/archive/refs/tags/v1.1.0.tar.gz")
    #expect(peon.rawURL("sounds/PeonReady1.wav").absoluteString
            == "https://raw.githubusercontent.com/PeonPing/og-packs/v1.1.0/peon/sounds/PeonReady1.wav")
    #expect(peon.matches("warcraft") && peon.matches("work") && !peon.matches("glados"))
    let quotes = registry.packs[1]
    #expect(quotes.previews == [.init(path: "sounds/a.mp3", label: "A line")])
    #expect(quotes.manifestURL.absoluteString == "https://raw.githubusercontent.com/someone/quotes/v1.0.0/openpeon.json")
}

@Test func versionsCompareNumerically() {
    #expect(PackVersion.isNewer("1.10.0", than: "1.9.3"))
    #expect(PackVersion.isNewer("2.0", than: "1.9.9"))
    #expect(!PackVersion.isNewer("1.0.0", than: "1.0.0"))
    #expect(!PackVersion.isNewer("1.0.0-beta", than: "1.0.0"))
    #expect(!PackVersion.isNewer("latest", than: "1.0.0"))
}

@Test func audioMustStartLikeItsFormat() {
    #expect(AudioMagic.matches(Data("RIFF....WAVE".utf8), path: "a.wav"))
    #expect(AudioMagic.matches(Data("OggS\0\u{2}".utf8), path: "a.ogg"))
    #expect(AudioMagic.matches(Data("ID3\u{4}\0".utf8), path: "a.mp3"))
    #expect(AudioMagic.matches(Data([0xFF, 0xF3, 0x44, 0x00]), path: "a.mp3"))
    #expect(!AudioMagic.matches(Data("#!/bin/sh\n".utf8), path: "a.mp3"))
    #expect(!AudioMagic.matches(Data("RIFF....".utf8), path: "a.mp3"))
    #expect(!AudioMagic.matches(Data("RIFF....".utf8), path: "a.aiff"))
}

// MARK: - Installer

/// A pack as the registry's host would serve it, file by file. A script sits beside the sounds and is
/// never asked for; one line is not audio, and one names a file the host does not have.
private struct PackServer {
    let files: [String: Data]
    let manifest: Data

    init(lineSHA: String? = nil) {
        let sha = lineSHA.map { ", \"sha256\": \"\($0)\"" } ?? ""
        manifest = Data("""
        { "cesp_version": "1.0", "name": "peon", "display_name": "Orc Peon", "version": "1.1.0",
          "categories": {
            "session.start": { "sounds": [
              { "file": "sounds/Ready.wav", "label": "Ready to work."\(sha) },
              { "file": "sounds/Fake.mp3", "label": "Fake" },
              { "file": "sounds/Missing.wav", "label": "Missing" },
              { "file": "../escape.wav", "label": "Escape" }
            ] },
            "task.complete": { "sounds": [ { "file": "sounds/Ready.wav", "label": "Again" } ] }
          } }
        """.utf8)
        files = [
            "openpeon.json": manifest,
            "sounds/Ready.wav": Data("RIFF\u{24}\0\0\0WAVEfmt ".utf8),
            "sounds/Fake.mp3": Data("not audio".utf8),
            "install.sh": Data("#!/bin/sh\necho hi\n".utf8),
        ]
    }

    var fetch: SoundPackInstaller.Fetch {
        let files = files
        return { path in
            guard let data = files[path] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    func entry(sha: String?) -> SoundRegistry.Entry {
        SoundRegistry.Entry(name: "peon", displayName: "Orc Peon", version: "1.1.0", sourceRepo: "PeonPing/og-packs",
                            sourceRef: "v1.1.0", sourcePath: "peon", manifestSHA256: sha)
    }
}

private func scratchFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("packs-\(UUID().uuidString)", isDirectory: true)
}

@Test func installWritesOnlyTheManifestAndTheAudioThatPasses() async throws {
    let server = PackServer()
    let packs = scratchFolder()
    defer { try? FileManager.default.removeItem(at: packs) }
    let result = try await SoundPackInstaller.install(server.entry(sha: SoundPackInstaller.sha256(server.manifest)),
                                                      into: packs, fetch: server.fetch)
    #expect(result.skippedLines == 3)   // not audio, not on the host, and outside the pack
    #expect(result.pack.id == "peon" && result.pack.origin == .clinic)
    let files = try FileManager.default.subpathsOfDirectory(atPath: packs.appendingPathComponent("peon").path).sorted()
    #expect(files == ["openpeon.json", "sounds", "sounds/Ready.wav"])
    // Installing again replaces the folder in place, and the scan finds it.
    _ = try await SoundPackInstaller.install(server.entry(sha: nil), into: packs, fetch: server.fetch)
    #expect(SoundPackInstaller.scan(packs, origin: .clinic).map(\.id) == ["peon"])
}

@Test func installRefusesAManifestTheRegistryDidNotPublish() async throws {
    let server = PackServer()
    let packs = scratchFolder()
    defer { try? FileManager.default.removeItem(at: packs) }
    await #expect(throws: SoundPackInstaller.Failure.manifestChecksum) {
        try await SoundPackInstaller.install(server.entry(sha: String(repeating: "0", count: 64)), into: packs, fetch: server.fetch)
    }
    #expect(SoundPackInstaller.scan(packs, origin: .clinic).isEmpty)
}

@Test func installRefusesALineWhoseChecksumDisagrees() async throws {
    let server = PackServer(lineSHA: String(repeating: "a", count: 64))
    let packs = scratchFolder()
    defer { try? FileManager.default.removeItem(at: packs) }
    await #expect(throws: SoundPackInstaller.Failure.lineChecksum("sounds/Ready.wav")) {
        try await SoundPackInstaller.install(server.entry(sha: nil), into: packs, fetch: server.fetch)
    }
    #expect(!FileManager.default.fileExists(atPath: packs.appendingPathComponent("peon").path))
}

// MARK: - Router

/// Deterministic randomness: the tests below care which line is *not* picked, not which one is.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func pack(_ categories: [CESPCategory: [String]]) -> CESPManifest {
    CESPManifest(name: "test", displayName: "Test", categories: Dictionary(uniqueKeysWithValues: categories.map { category, files in
        (category.rawValue, CESPManifest.Category(sounds: files.map { CESPManifest.Line(file: "sounds/\($0)", label: $0) }))
    }))
}

private func played(_ d: SoundRouter.Decision) -> String? {
    if case .play(let cue) = d { return cue.line.file.replacingOccurrences(of: "sounds/", with: "") }
    return nil
}

@Test func routerNeverRepeatsTheLastLine() {
    var router = SoundRouter()
    var random = SeededRandom(state: 7)
    let manifest = pack([.taskComplete: ["a.wav", "b.wav", "c.wav"]])
    var heard: [String] = []
    var now = Date(timeIntervalSince1970: 0)
    for _ in 0..<30 {
        now += 1
        if let line = played(router.decide(.turnFinished, session: "s", manifest: manifest, settings: SoundSettings(), now: now, using: &random)) {
            heard.append(line)
        }
    }
    #expect(heard.count == 30)
    #expect(zip(heard, heard.dropFirst()).allSatisfy { $0 != $1 })
    #expect(Set(heard) == ["a.wav", "b.wav", "c.wav"])
}

@Test func routerHoldsWithinTheDebounceAndPassesWhenThePackIsSilent() {
    var router = SoundRouter()
    let manifest = pack([.taskComplete: ["a.wav"]])
    let t = Date(timeIntervalSince1970: 100)
    #expect(played(router.decide(.turnFinished, session: "s", manifest: manifest, settings: SoundSettings(), now: t)) == "a.wav")
    #expect(router.decide(.runSucceeded, session: nil, manifest: manifest, settings: SoundSettings(), now: t + 0.2) == .hold)
    #expect(played(router.decide(.turnFinished, session: "s", manifest: manifest, settings: SoundSettings(), now: t + 0.6)) == "a.wav")
    // No line for the category, no pack, or the witness switched off: the old notification sound applies.
    #expect(router.decide(.permissionNeeded, session: "s", manifest: manifest, settings: SoundSettings(), now: t + 5) == .pass)
    #expect(router.decide(.turnFinished, session: "s", manifest: nil, settings: SoundSettings(), now: t + 5) == .pass)
    var off = SoundSettings()
    off.disabledWitnesses = [.turnFinished]
    #expect(router.decide(.turnFinished, session: "s", manifest: manifest, settings: off, now: t + 5) == .pass)
    #expect(played(router.decide(.runSucceeded, session: nil, manifest: manifest, settings: off, now: t + 5)) == "a.wav")
    off.disabledCategories = [.taskComplete]
    #expect(router.decide(.runSucceeded, session: nil, manifest: manifest, settings: off, now: t + 10) == .pass)
    off = SoundSettings(); off.enabled = false
    #expect(router.decide(.runSucceeded, session: nil, manifest: manifest, settings: off, now: t + 15) == .pass)
}

@Test func thirdPromptInTenSecondsIsSpam() {
    var router = SoundRouter()
    let manifest = pack([.taskAcknowledge: ["ok.wav"], .userSpam: ["stop.wav"]])
    let t = Date(timeIntervalSince1970: 0)
    let s = SoundSettings()
    #expect(played(router.decide(.promptSubmitted, session: "a", manifest: manifest, settings: s, now: t)) == "ok.wav")
    #expect(played(router.decide(.promptSubmitted, session: "a", manifest: manifest, settings: s, now: t + 3)) == "ok.wav")
    // Another session's prompts are counted on their own.
    #expect(played(router.decide(.promptSubmitted, session: "b", manifest: manifest, settings: s, now: t + 4)) == "ok.wav")
    #expect(played(router.decide(.promptSubmitted, session: "a", manifest: manifest, settings: s, now: t + 6)) == "stop.wav")
    // The count starts again after it fires.
    #expect(played(router.decide(.promptSubmitted, session: "a", manifest: manifest, settings: s, now: t + 7)) == "ok.wav")
    // Spread out, prompts never add up.
    #expect(played(router.decide(.promptSubmitted, session: "c", manifest: manifest, settings: s, now: t + 20)) == "ok.wav")
    #expect(played(router.decide(.promptSubmitted, session: "c", manifest: manifest, settings: s, now: t + 31)) == "ok.wav")
    #expect(played(router.decide(.promptSubmitted, session: "c", manifest: manifest, settings: s, now: t + 42)) == "ok.wav")
}

@Test func sessionStartsAreNotAChorus() {
    var router = SoundRouter()
    let manifest = pack([.sessionStart: ["hi.wav"]])
    let t = Date(timeIntervalSince1970: 0)
    #expect(played(router.decide(.sessionStarted, session: "a", manifest: manifest, settings: SoundSettings(), now: t)) == "hi.wav")
    #expect(router.decide(.sessionStarted, session: "b", manifest: manifest, settings: SoundSettings(), now: t + 5) == .hold)
    #expect(played(router.decide(.sessionStarted, session: "c", manifest: manifest, settings: SoundSettings(), now: t + 31)) == "hi.wav")
}

@Test func onlyAMoreUrgentLineCutsIn() {
    var router = SoundRouter()
    let manifest = pack([.taskComplete: ["done.wav"], .inputRequired: ["you.wav"], .taskAcknowledge: ["ok.wav"]])
    let t = Date(timeIntervalSince1970: 0)
    #expect(router.decide(.promptSubmitted, session: "a", manifest: manifest, settings: SoundSettings(), playing: .taskComplete, now: t) == .hold)
    #expect(router.decide(.turnFinished, session: "a", manifest: manifest, settings: SoundSettings(), playing: .taskComplete, now: t) == .hold)
    guard case .play(let cue) = router.decide(.permissionNeeded, session: "a", manifest: manifest, settings: SoundSettings(), playing: .taskComplete, now: t)
    else { Issue.record("permission should cut in"); return }
    #expect(cue.interrupting && cue.category == .inputRequired)
}

@Test func theTabOnScreenCanBeQuiet() {
    var router = SoundRouter()
    let manifest = pack([.taskComplete: ["done.wav"]])
    var s = SoundSettings()
    #expect(played(router.decide(.turnFinished, session: "a", manifest: manifest, settings: s, onScreen: true, now: Date(timeIntervalSince1970: 0))) == "done.wav")
    s.quietOnScreen = true
    #expect(router.decide(.turnFinished, session: "a", manifest: manifest, settings: s, onScreen: true, now: Date(timeIntervalSince1970: 10)) == .hold)
}

@Test func settingsSurviveValuesFromANewerBuild() throws {
    let json = Data(#"{"enabled":false,"volume":3,"defaultPack":"peon","disabledCategories":["task.error","task.future"],"disabledWitnesses":["turnFinished","somethingNew"],"quietOnScreen":true}"#.utf8)
    let s = SoundSettings(json: json)
    #expect(!s.enabled && s.volume == 1 && s.defaultPack == "peon" && s.quietOnScreen)
    #expect(s.disabledCategories == [.taskError] && s.disabledWitnesses == [.turnFinished])
    #expect(SoundSettings(json: s.encoded()) == s)
    #expect(SoundSettings(json: nil) == SoundSettings())
}
