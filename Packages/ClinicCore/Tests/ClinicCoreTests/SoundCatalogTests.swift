import Foundation
import Testing
@testable import ClinicCore

private func entry(_ name: String, language: String = "en", tags: [String] = [], quality: String? = "silver",
                   trust: String? = "community", lines: Int = 10, added: String? = nil) -> SoundRegistry.Entry {
    var e = SoundRegistry.Entry(name: name, displayName: name.capitalized, sourceRepo: "a/b", sourceRef: "v1", tags: tags)
    e.language = language
    e.quality = quality
    e.trustTier = trust
    e.soundCount = lines
    e.added = added
    return e
}

private let franchises = SoundFranchises(franchises: [
    .init(name: "Warcraft", keys: ["warcraft", "peon"]),
    .init(name: "Portal", keys: ["portal"]),
])

private let catalog = SoundCatalog(entries: [
    entry("peon", tags: ["gaming", "warcraft"], trust: "official", lines: 27, added: "2026-02-12"),
    entry("peasant_ja", language: "ja", tags: ["gaming", "warcraft"], quality: "gold", lines: 20, added: "2026-03-01"),
    entry("glados", tags: ["gaming", "portal"], quality: "gold", trust: "verified", lines: 23, added: "2026-01-05"),
    entry("lich", language: "zh-CN", tags: ["gaming", "warcraft"], lines: 45, added: "2026-04-01"),
    entry("office", language: "en,ru", tags: ["tv"], quality: nil, lines: 12, added: "2026-05-01"),
], franchises: franchises, lines: ["peon": ["Work, work.", "Ready to work?"]])

private func names(_ packs: [SoundCatalog.Pack]) -> [String] { packs.map(\.id) }

@Test func franchiseComesFromTheRegistryThenTheNameThenTheTags() {
    #expect(catalog.pack("peon")?.franchise == "Warcraft")
    #expect(catalog.pack("glados")?.franchise == "Portal")
    #expect(catalog.pack("office")?.franchise == nil)
    var own = entry("x", tags: ["portal"])
    own.franchise = "Half-Life"
    #expect(franchises.franchise(for: own) == "Half-Life")
}

@Test func languagesFoldRegionsAndSplitLists() {
    #expect(catalog.pack("lich")?.entry.languages == ["zh"])
    #expect(catalog.pack("office")?.entry.languages == ["en", "ru"])
    var none = entry("y")
    none.language = nil
    #expect(none.languages.isEmpty)
}

@Test func valuesInOneFacetWidenAndFacetsNarrow() {
    var filter = SoundPackFilter()
    filter.toggle("ja", in: .language)
    filter.toggle("zh", in: .language)
    #expect(Set(names(catalog.visible(filter))) == ["peasant_ja", "lich"])
    filter.toggle("gold", in: .quality)
    #expect(names(catalog.visible(filter)) == ["peasant_ja"])
    filter.toggle("gold", in: .quality)
    filter.toggle("zh", in: .language)
    filter.toggle("ja", in: .language)
    #expect(filter.activeCount == 0)
    filter.toggle(SoundCatalog.noFranchise, in: .franchise)
    #expect(names(catalog.visible(filter)) == ["office"])
}

@Test func countsLeaveTheirOwnFacetOut() {
    var filter = SoundPackFilter()
    filter.toggle("Warcraft", in: .franchise)
    // Languages are counted within Warcraft…
    #expect(catalog.counts(.language, filter) == ["en": 1, "ja": 1, "zh": 1])
    // …but franchises are counted as if none were ticked, so Portal still says what it would show.
    #expect(catalog.counts(.franchise, filter) == ["Warcraft": 3, "Portal": 1, SoundCatalog.noFranchise: 1])
    filter.toggle("ja", in: .language)
    #expect(catalog.counts(.franchise, filter) == ["Warcraft": 1])
}

@Test func searchReadsFranchisesAndSpokenLines() {
    var filter = SoundPackFilter()
    filter.query = "work work"
    #expect(names(catalog.visible(filter)) == ["peon"])
    filter.query = "warcraft"
    #expect(Set(names(catalog.visible(filter))) == ["peon", "peasant_ja", "lich"])
    filter.query = "  "
    #expect(catalog.visible(filter).count == 5)
}

@Test func aSearchRanksThePhraseAboveScatteredWords() {
    let packs = SoundCatalog(entries: [
        entry("aaa", tags: ["work", "gaming"], trust: "official"),
        entry("zzz"),
    ], franchises: franchises, lines: ["aaa": ["Back to it.", "Gaming the system"], "zzz": ["Work, work."]])
    var filter = SoundPackFilter()
    filter.query = "work work"
    // Both hold both words; only the Peon-like pack says the phrase, so it outranks the official one.
    #expect(names(packs.visible(filter)) == ["zzz", "aaa"])
    filter.query = "zzz"
    #expect(names(packs.visible(filter)) == ["zzz"])
}

@Test func sortsByTrustThenQualityThenName() {
    var filter = SoundPackFilter()
    #expect(names(catalog.visible(filter)) == ["peon", "glados", "peasant_ja", "lich", "office"])
    filter.sort = .mostLines
    #expect(names(catalog.visible(filter)).first == "lich")
    filter.sort = .newest
    #expect(names(catalog.visible(filter)) == ["office", "lich", "peasant_ja", "peon", "glados"])
}

@Test func valuesListEveryFranchiseMostCommonFirst() {
    #expect(catalog.values(.franchise).map(\.value) == ["Warcraft", SoundCatalog.noFranchise, "Portal"])
    #expect(catalog.values(.language).first?.value == "en")
}

@Test func theBundledFranchisesLoad() {
    #expect(SoundFranchises.bundled.franchises.count > 20)
    let peon = SoundRegistry.Entry(name: "peon", displayName: "Orc Peon", sourceRepo: "PeonPing/og-packs", sourceRef: "v1",
                                   tags: ["gaming", "warcraft", "blizzard", "rts"])
    #expect(SoundFranchises.bundled.franchise(for: peon) == "Warcraft")
}
