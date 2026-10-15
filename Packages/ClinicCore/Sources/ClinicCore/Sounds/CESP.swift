import Foundation

/// The nine event categories of the Coding Event Sound Pack Specification, v1.0 (ADR-199).
///
/// The spec forbids a player inventing categories, so Clinic's own witnesses map onto these rather
/// than adding to them.
public enum CESPCategory: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case sessionStart = "session.start"
    case taskAcknowledge = "task.acknowledge"
    case taskComplete = "task.complete"
    case taskError = "task.error"
    case inputRequired = "input.required"
    case resourceLimit = "resource.limit"
    case userSpam = "user.spam"
    case sessionEnd = "session.end"
    case taskProgress = "task.progress"

    public var id: String { rawValue }

    /// Core categories a player must support; the other three are optional in the spec.
    public var isCore: Bool {
        switch self {
        case .userSpam, .sessionEnd, .taskProgress: false
        default: true
        }
    }

    public var title: String {
        switch self {
        case .sessionStart: "Session starts"
        case .taskAcknowledge: "Work accepted"
        case .taskComplete: "Work finished"
        case .taskError: "Something failed"
        case .inputRequired: "Needs you"
        case .resourceLimit: "Limit reached"
        case .userSpam: "Too many prompts"
        case .sessionEnd: "Session ends"
        case .taskProgress: "Still working"
        }
    }

    public var symbol: String {
        switch self {
        case .sessionStart: "play.circle"
        case .taskAcknowledge: "hand.thumbsup"
        case .taskComplete: "checkmark.circle"
        case .taskError: "xmark.octagon"
        case .inputRequired: "hand.raised"
        case .resourceLimit: "gauge.with.dots.needle.100percent"
        case .userSpam: "exclamationmark.bubble"
        case .sessionEnd: "stop.circle"
        case .taskProgress: "hourglass"
        }
    }

    /// Which line wins when two want to play at once (ADR-199): a lower number cuts in on a higher one.
    public var rank: Int {
        switch self {
        case .inputRequired: 0
        case .taskError: 1
        case .resourceLimit: 2
        case .taskComplete: 3
        default: 4
        }
    }
}

/// One pack's `openpeon.json`.
///
/// Decoded tolerantly: a category name Clinic does not know is kept (an alias may point at it), and a
/// sound entry without a `file` is dropped rather than failing the whole pack.
public struct CESPManifest: Codable, Sendable, Hashable {
    public struct Author: Codable, Sendable, Hashable {
        public var name: String?
        public var github: String?
    }

    public struct Line: Codable, Sendable, Hashable {
        public var file: String
        public var label: String
        public var sha256: String?
        public var icon: String?

        public init(file: String, label: String, sha256: String? = nil, icon: String? = nil) {
            self.file = file; self.label = label; self.sha256 = sha256; self.icon = icon
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = try c.decode(String.self, forKey: .file)
            label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
            sha256 = try? c.decodeIfPresent(String.self, forKey: .sha256)
            icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        }

        /// The path inside the pack: the spec's rule that a bare file name lives in `sounds/`.
        public var path: String { file.contains("/") ? file : "sounds/" + file }
    }

    public struct Category: Codable, Sendable, Hashable {
        public var sounds: [Line]
        public var icon: String?

        public init(sounds: [Line], icon: String? = nil) { self.sounds = sounds; self.icon = icon }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sounds = ((try? c.decode([Lossy<Line>].self, forKey: .sounds)) ?? []).compactMap(\.value)
            icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        }
    }

    public var cespVersion: String
    public var name: String
    public var displayName: String
    public var version: String
    public var description: String?
    public var author: Author?
    public var license: String?
    public var language: String?
    public var homepage: String?
    public var icon: String?
    public var tags: [String]?
    public var categories: [String: Category]
    public var categoryAliases: [String: String]?

    enum CodingKeys: String, CodingKey {
        case cespVersion = "cesp_version", name, displayName = "display_name", version, description, author
        case license, language, homepage, icon, tags, categories, categoryAliases = "category_aliases"
    }

    public init(cespVersion: String = "1.0", name: String, displayName: String, version: String = "1.0.0",
                categories: [String: Category], categoryAliases: [String: String]? = nil) {
        self.cespVersion = cespVersion; self.name = name; self.displayName = displayName; self.version = version
        self.categories = categories; self.categoryAliases = categoryAliases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cespVersion = try c.decode(String.self, forKey: .cespVersion)
        name = try c.decode(String.self, forKey: .name)
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? name
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? "0.0.0"
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        author = try? c.decodeIfPresent(Author.self, forKey: .author)
        license = try? c.decodeIfPresent(String.self, forKey: .license)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        homepage = try? c.decodeIfPresent(String.self, forKey: .homepage)
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        tags = try? c.decodeIfPresent([String].self, forKey: .tags)
        categories = (try? c.decodeIfPresent([String: Category].self, forKey: .categories)) ?? [:]
        categoryAliases = try? c.decodeIfPresent([String: String].self, forKey: .categoryAliases)
    }

    /// The lines for a category, by the spec's resolution order: the category itself, then any legacy
    /// name the pack's aliases map onto it. Empty when the pack has nothing, which means silence.
    public func lines(for category: CESPCategory) -> [Line] {
        if let direct = categories[category.rawValue], !direct.sounds.isEmpty { return direct.sounds }
        for (legacy, target) in categoryAliases ?? [:] where target == category.rawValue {
            if let lines = categories[legacy]?.sounds, !lines.isEmpty { return lines }
        }
        return []
    }

    /// Every category this pack can voice.
    public var voicedCategories: [CESPCategory] { CESPCategory.allCases.filter { !lines(for: $0).isEmpty } }

    /// Every line, once, for validation.
    public var allLines: [Line] {
        var seen = Set<String>()
        return categories.values.flatMap(\.sounds).filter { seen.insert($0.path).inserted }
    }

    // MARK: Rules the spec states

    /// `^[a-z0-9][a-z0-9_-]*$`, 1–64 characters.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first else { return false }
        let lower = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let rest = lower.union(CharacterSet(charactersIn: "_-"))
        return lower.contains(first) && name.unicodeScalars.allSatisfy(rest.contains)
    }

    /// A relative path with forward slashes, no `..` or `.` component, and every component made of
    /// `[a-zA-Z0-9._-]`. The file name rule is the spec's; holding folders to it too costs nothing.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}

/// Decodes an element or yields nil, so one bad entry does not cost its neighbours.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
