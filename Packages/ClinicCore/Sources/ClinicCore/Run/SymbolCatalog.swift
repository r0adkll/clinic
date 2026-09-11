import Foundation

/// The SF Symbols this Mac has, for the run configuration icon picker (ADR-125).
///
/// The names come from the system's own catalogue (`CoreGlyphs.bundle`) — data, not API: AppKit
/// cannot enumerate symbols, and a run configuration's icon may be any name, because Claude writes
/// `run.json` and reaches for symbols no curated list would hold. Whether a name can actually be
/// drawn is an AppKit question, and stays in the app.
public struct SymbolCatalog: Sendable, Equatable {
    /// Every usable symbol, in the order the SF Symbols app shows them.
    public let names: [String]
    let known: Set<String>
    let categoriesOf: [String: [String]]
    let terms: [String: [String]]
    /// The system's outline → filled pairs, which are not always `name + ".fill"`
    /// (`video.badge.checkmark` fills as `video.fill.badge.checkmark`).
    let fillOf: [String: String]
    let plainOf: [String: String]

    public static let systemResources = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources"

    /// Localized and right-to-left variants of a drawing that is already listed; they only clutter a search.
    static let localizedVariant = #"\.(ar|he|hi|ja|ko|th|zh|kn|gu|mr|ta|te|ml|or|pa|si|km|my|ne|bn|ur|rtl)(\.|$)"#

    /// Traits rather than subjects: everything is in one, so browsing by them is no help.
    public static let traitCategories: Set<String> = ["all", "multicolor", "variable", "indices"]

    /// What the picker offers before anyone searches: the things a project runs.
    public static let suggested = ["play.fill", "desktopcomputer", "iphone", "ipad", "applewatch", "appletv", "globe",
                                   "server.rack", "hammer", "wrench.and.screwdriver", "terminal", "testtube.2", "ladybug",
                                   "shippingbox", "bolt", "paintbrush", "trash", "doc.text", "arrow.triangle.2.circlepath",
                                   "square.stack", "chart.bar", "cloud", "lock", "gearshape"]

    /// Builds a catalogue from the catalogue files' contents. `restricted` are Apple's own marks,
    /// which may only stand for Apple's products, so they are left out; `order` is the system's.
    public static func make(symbols: [String], restricted: Set<String> = [], categories: [String: [String]] = [:],
                            terms: [String: [String]] = [:], order: [String] = [], fills: [String: String] = [:]) -> SymbolCatalog {
        let variant = try? NSRegularExpression(pattern: localizedVariant)
        let kept = symbols.filter { name in
            guard !restricted.contains(name) else { return false }
            guard let variant else { return true }
            return variant.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil
        }
        var rank: [String: Int] = [:]
        for (i, name) in order.enumerated() where rank[name] == nil { rank[name] = i }
        let sorted = kept.sorted { a, b in
            let ra = rank[a] ?? Int.max, rb = rank[b] ?? Int.max
            return ra == rb ? a < b : ra < rb
        }
        var plain: [String: String] = [:]
        for (outline, filled) in fills where plain[filled] == nil { plain[filled] = outline }
        return SymbolCatalog(names: sorted, known: Set(sorted), categoriesOf: categories,
                             terms: terms.mapValues { $0.map { $0.lowercased() } }, fillOf: fills, plainOf: plain)
    }

    /// Reads the system's catalogue; nil when a future macOS has moved it.
    public static func system(resources: String = systemResources) -> SymbolCatalog? {
        guard let availability = NSDictionary(contentsOfFile: resources + "/name_availability.plist") as? [String: Any],
              let symbols = availability["symbols"] as? [String: String], !symbols.isEmpty else { return nil }
        return make(symbols: Array(symbols.keys),
                    restricted: Set((NSDictionary(contentsOfFile: resources + "/symbol_restrictions.strings") as? [String: String] ?? [:]).keys),
                    categories: (NSDictionary(contentsOfFile: resources + "/symbol_categories.plist") as? [String: [String]]) ?? [:],
                    terms: (NSDictionary(contentsOfFile: resources + "/symbol_search.plist") as? [String: [String]]) ?? [:],
                    order: (NSArray(contentsOfFile: resources + "/symbol_order.plist") as? [String]) ?? [],
                    fills: (NSDictionary(contentsOfFile: resources + "/nofill_to_fill.strings") as? [String: String]) ?? [:])
    }

    /// Names matching `query` — their own name, or the system's search terms for them — in `category`
    /// when one is given.
    public func symbols(matching query: String, in category: String? = nil) -> [String] {
        let pool = category.map { key in names.filter { categoriesOf[$0]?.contains(key) ?? false } } ?? names
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return pool }
        return pool.filter { name in
            if name.replacingOccurrences(of: ".", with: " ").contains(q) { return true }
            return terms[name]?.contains { $0.contains(q) } ?? false
        }
    }

    // MARK: Variants

    /// One way of drawing the same thing: filled or not, on its own or in a circle or square.
    public struct SymbolVariant: Identifiable, Hashable, Sendable {
        public let name: String
        public let label: String
        public let isFilled: Bool
        public var style: SymbolStyle
        public var id: String { name }
    }

    /// The ways any symbol may be drawn, in the order the picker offers them (ADR-125).
    public enum SymbolStyle: String, CaseIterable, Identifiable, Sendable {
        case plain, filled, circle, circleFilled, square, squareFilled

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .plain: "Plain"
            case .filled: "Filled"
            case .circle: "Circle"
            case .circleFilled: "Circle Filled"
            case .square: "Square"
            case .squareFilled: "Square Filled"
            }
        }

        var enclosure: String? {
            switch self {
            case .plain, .filled: nil
            case .circle, .circleFilled: "circle"
            case .square, .squareFilled: "square"
            }
        }

        var isFilled: Bool {
            switch self {
            case .filled, .circleFilled, .squareFilled: true
            case .plain, .circle, .square: false
            }
        }
    }

    /// Shapes a symbol can be enclosed in, in the order the picker offers them.
    private static let enclosures = ["circle", "square"]

    /// The subject `name` draws, without the fill or the enclosure: `hammer.circle.fill` → `hammer`.
    /// `.slash` and badges stay, since dropping them would change the meaning.
    ///
    /// A trailing `.square` is only an enclosure when what is left is a symbol in its own right:
    /// `square.and.arrow.up.on.square` is a subject, and stripping it invents a name nothing draws.
    public func family(of name: String) -> String {
        let outline = plainOf[name] ?? name
        for enclosure in Self.enclosures where outline.hasSuffix("." + enclosure) {
            let core = String(outline.dropLast(enclosure.count + 1))
            if !core.isEmpty, known.contains(core) { return core }
        }
        return outline
    }

    /// The name for one style of a family, when this Mac has it.
    public func name(_ family: String, style: SymbolStyle) -> String? {
        let base = style.enclosure.map { family + "." + $0 } ?? family
        guard style.isFilled else { return known.contains(base) ? base : nil }
        guard let filled = fillOf[base], known.contains(filled) else { return nil }
        return filled
    }

    /// How `name` is drawn.
    public func style(of name: String) -> SymbolStyle {
        let filled = plainOf[name] != nil
        let outline = plainOf[name] ?? name
        for enclosure in Self.enclosures where outline.hasSuffix("." + enclosure) {
            let core = String(outline.dropLast(enclosure.count + 1))
            guard !core.isEmpty, known.contains(core) else { continue }
            return enclosure == "circle" ? (filled ? .circleFilled : .circle) : (filled ? .squareFilled : .square)
        }
        return filled ? .filled : .plain
    }

    /// One entry per subject rather than one per drawing: `hammer`, not `hammer`, `hammer.fill`,
    /// `hammer.circle` and `hammer.circle.fill` (ADR-125). Order follows the symbols themselves.
    public func families(matching query: String, in category: String? = nil) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for name in symbols(matching: query, in: category) {
            let core = family(of: name)
            guard seen.insert(core).inserted else { continue }
            out.append(core)
        }
        return out
    }

    /// The ways this Mac can draw `name`'s subject: plain and filled, and the same inside a circle or
    /// a square, keeping only the ones that exist (ADR-125). One entry means there is nothing to
    /// choose. `.slash` and badges stay part of the subject: dropping them would change the meaning.
    public func variants(of name: String) -> [SymbolVariant] {
        let outline = plainOf[name] ?? name
        var core = outline
        var currentEnclosure: String?
        for enclosure in Self.enclosures where outline.hasSuffix("." + enclosure) {
            core = String(outline.dropLast(enclosure.count + 1))
            currentEnclosure = enclosure
            break
        }
        // A name whose "enclosure" is the subject itself (`circle`, `square.fill`) has no core to vary.
        if core.isEmpty { core = outline; currentEnclosure = nil }
        var out: [SymbolVariant] = []
        for style in SymbolStyle.allCases {
            guard let variant = self.name(core, style: style) else { continue }
            out.append(SymbolVariant(name: variant, label: style.label, isFilled: style.isFilled, style: style))
        }
        if !out.contains(where: { $0.name == name }) {
            let style = self.style(of: name)
            out.insert(SymbolVariant(name: name, label: currentEnclosure == nil ? style.label : "Current",
                                     isFilled: style.isFilled, style: style), at: 0)
        }
        return out.count > 1 ? out : []
    }

    /// The catalogue's subjects, in the system's order, without the traits.
    public struct Category: Identifiable, Hashable, Sendable {
        public let key: String
        public let label: String
        public let symbol: String
        public var id: String { key }
    }

    public static func categories(resources: String = systemResources) -> [Category] {
        guard let list = NSArray(contentsOfFile: resources + "/categories.plist") as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let key = entry["key"] as? String, !traitCategories.contains(key) else { return nil }
            return Category(key: key, label: label(for: key), symbol: entry["icon"] as? String ?? "square.grid.2x2")
        }
    }

    static func label(for key: String) -> String {
        switch key {
        case "whatsnew": "What's New"
        case "objectsandtools": "Objects & Tools"
        case "cameraandphotos": "Camera & Photos"
        case "privacyandsecurity": "Privacy & Security"
        case "textformatting": "Text Formatting"
        case "human": "People"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }
}
