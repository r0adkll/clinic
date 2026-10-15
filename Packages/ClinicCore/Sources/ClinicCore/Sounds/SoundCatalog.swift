import Foundation

/// Which franchise a pack belongs to (ADR-200).
///
/// The registry does not say. openpeon.com keeps the list in its own source, and
/// `scripts/sound-franchises` copies it into a bundled resource. A pack's franchise is the registry's
/// own, when it starts serving one; else the franchise whose keys hold the pack's name; else the first
/// of its tags that a franchise holds, the order the site resolves them in.
public struct SoundFranchises: Sendable {
    public struct Franchise: Codable, Sendable, Hashable {
        public var name: String
        public var url: String
        public var keys: [String]

        public init(name: String, url: String = "", keys: [String]) { self.name = name; self.url = url; self.keys = keys }
    }

    public let franchises: [Franchise]
    private let byKey: [String: String]

    public init(franchises: [Franchise]) {
        self.franchises = franchises
        var byKey: [String: String] = [:]
        for franchise in franchises {
            for key in franchise.keys where byKey[key.lowercased()] == nil { byKey[key.lowercased()] = franchise.name }
        }
        self.byKey = byKey
    }

    public static let bundled: SoundFranchises = {
        struct File: Decodable { let franchises: [Franchise] }
        guard let url = Bundle.module.url(forResource: "sound-franchises", withExtension: "json"),
              let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return SoundFranchises(franchises: [])
        }
        return SoundFranchises(franchises: file.franchises)
    }()

    public func franchise(for entry: SoundRegistry.Entry) -> String? {
        if let own = entry.franchise, !own.isEmpty { return own }
        if let byName = byKey[entry.name.lowercased()] { return byName }
        return entry.tags.lazy.compactMap { self.byKey[$0.lowercased()] }.first
    }

    public func url(of name: String) -> URL? {
        franchises.first { $0.name == name }.flatMap { URL(string: $0.url) }
    }
}

/// The filters on the Sounds screen's left column (ADR-200).
///
/// Several values in one facet widen the list (Japanese *or* Chinese); values in different facets
/// narrow it (Japanese *and* gold). Each facet's counts are taken with every *other* facet applied,
/// so a count says what ticking that box would show.
public struct SoundPackFilter: Sendable, Hashable {
    public enum Facet: String, CaseIterable, Sendable {
        case language, franchise, tag, quality, trust
    }

    public enum Sort: String, CaseIterable, Sendable, Identifiable {
        case recommended, name, mostLines, newest, recentlyUpdated
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .recommended: "Recommended"
            case .name: "Name"
            case .mostLines: "Most lines"
            case .newest: "Newest"
            case .recentlyUpdated: "Recently updated"
            }
        }
    }

    public var query = ""
    public var sort: Sort = .recommended
    private var picked: [Facet: Set<String>] = [:]

    public init() {}

    public func values(_ facet: Facet) -> Set<String> { picked[facet] ?? [] }
    public func contains(_ value: String, in facet: Facet) -> Bool { values(facet).contains(value) }

    public mutating func toggle(_ value: String, in facet: Facet) {
        var set = values(facet)
        if set.remove(value) == nil { set.insert(value) }
        picked[facet] = set.isEmpty ? nil : set
    }

    public mutating func set(_ values: Set<String>, in facet: Facet) { picked[facet] = values.isEmpty ? nil : values }

    /// How many values are ticked, across every facet. The search is not counted.
    public var activeCount: Int { picked.values.reduce(0) { $0 + $1.count } }

    /// Untick everything and empty the search; the sort stays.
    public mutating func clear() { picked = [:]; query = "" }
}

/// The registry, ready to filter: each entry with its franchise and the text a search reads (ADR-200).
public struct SoundCatalog: Sendable {
    /// The franchise value that stands for "no franchise", so packs without one can be picked too.
    public static let noFranchise = ""

    public struct Pack: Sendable, Identifiable, Hashable {
        public let entry: SoundRegistry.Entry
        public let franchise: String?
        public var id: String { entry.name }
        /// Lower-cased, in the order a search ranks them: the names; the franchise, author and tags;
        /// the description and any spoken lines known.
        let nameText: String
        let aboutText: String
        let saysText: String
        var searchText: String { nameText + " " + aboutText + " " + saysText }

        /// How well a search matches: the whole phrase in the name first, then in what the pack is
        /// about, then in what it says, then every word somewhere.
        func relevance(_ phrase: String) -> Int {
            if phrase.isEmpty || nameText.contains(phrase) { return 0 }
            if aboutText.contains(phrase) { return 1 }
            return saysText.contains(phrase) ? 2 : 3
        }

        func value(_ facet: SoundPackFilter.Facet) -> [String] {
            switch facet {
            case .language: entry.languages
            case .franchise: [franchise ?? SoundCatalog.noFranchise]
            case .tag: entry.tags
            case .quality: entry.quality.map { [$0] } ?? []
            case .trust: [entry.trustTier ?? "community"]
            }
        }
    }

    public let packs: [Pack]

    /// - Parameter lines: spoken lines by pack name, from manifests already read, so a search for
    ///   "work work" finds the Peon.
    public init(entries: [SoundRegistry.Entry], franchises: SoundFranchises = .bundled, lines: [String: [String]] = [:]) {
        packs = entries.map { entry in
            let franchise = franchises.franchise(for: entry)
            func text(_ parts: [String]) -> String { SoundCatalog.searchable(parts.joined(separator: " ")) }
            return Pack(entry: entry, franchise: franchise,
                        nameText: text([entry.displayName, entry.name]),
                        aboutText: text([franchise ?? "", entry.authorName ?? ""] + entry.tags),
                        saysText: text([entry.description] + (lines[entry.name] ?? [])))
        }
    }

    public func pack(_ name: String) -> Pack? { packs.first { $0.id == name } }

    /// Lower case, letters and digits only, single spaces: so "work work" finds "Work, work."
    static func searchable(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    func matches(_ pack: Pack, _ filter: SoundPackFilter, skipping skipped: SoundPackFilter.Facet? = nil) -> Bool {
        let words = Self.searchable(filter.query).split(separator: " ")
        if !words.allSatisfy({ pack.searchText.contains($0) }) { return false }
        for facet in SoundPackFilter.Facet.allCases where facet != skipped {
            let wanted = filter.values(facet)
            if !wanted.isEmpty, wanted.isDisjoint(with: pack.value(facet)) { return false }
        }
        return true
    }

    /// What the list shows, in the filter's order. Under a search, *Recommended* puts the best matches first.
    public func visible(_ filter: SoundPackFilter) -> [Pack] {
        let kept = packs.filter { matches($0, filter) }
        let phrase = Self.searchable(filter.query)
        func rank(_ p: Pack) -> Int {
            (["official": 0, "verified": 1][p.entry.trustTier ?? ""] ?? 2) * 3 + (["gold": 0, "silver": 1][p.entry.quality ?? ""] ?? 2)
        }
        func byName(_ a: Pack, _ b: Pack) -> Bool {
            a.entry.displayName.localizedCaseInsensitiveCompare(b.entry.displayName) == .orderedAscending
        }
        return kept.sorted { a, b in
            switch filter.sort {
            case .recommended:
                a.relevance(phrase) != b.relevance(phrase) ? a.relevance(phrase) < b.relevance(phrase)
                    : rank(a) != rank(b) ? rank(a) < rank(b) : byName(a, b)
            case .name: byName(a, b)
            case .mostLines: (a.entry.soundCount ?? 0) != (b.entry.soundCount ?? 0) ? (a.entry.soundCount ?? 0) > (b.entry.soundCount ?? 0) : byName(a, b)
            case .newest: (a.entry.added ?? "") != (b.entry.added ?? "") ? (a.entry.added ?? "") > (b.entry.added ?? "") : byName(a, b)
            case .recentlyUpdated: (a.entry.updated ?? "") != (b.entry.updated ?? "") ? (a.entry.updated ?? "") > (b.entry.updated ?? "") : byName(a, b)
            }
        }
    }

    /// How many packs each value of a facet would show, with every other facet applied.
    public func counts(_ facet: SoundPackFilter.Facet, _ filter: SoundPackFilter) -> [String: Int] {
        var counts: [String: Int] = [:]
        for pack in packs where matches(pack, filter, skipping: facet) {
            for value in Set(pack.value(facet)) { counts[value, default: 0] += 1 }
        }
        return counts
    }

    /// Every value a facet has across the whole registry, most common first.
    public func values(_ facet: SoundPackFilter.Facet) -> [(value: String, total: Int)] {
        var totals: [String: Int] = [:]
        for pack in packs { for value in Set(pack.value(facet)) { totals[value, default: 0] += 1 } }
        return totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
